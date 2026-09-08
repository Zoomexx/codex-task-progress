import Foundation

/// Owns the single App Server connection used by the menu-bar app. The service
/// keeps only quota percentages, reset times, status, and the latest sync time.
final class UsageSyncService {
    static let shared = UsageSyncService()

    var onSnapshot: ((UsageSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "local.codex.usage-menu.sync")
    private let client = OfficialUsageClient()
    private var latestSnapshot: UsageSnapshot
    private var started = false

    // Only quota percentages, reset times, and the last successful read are
    // persisted. This prevents a brief reconnect from making the status bar
    // disappear while still labeling the cached value as not-current until a
    // fresh official response arrives.
    private static let cacheURL = URL(fileURLWithPath: "/private/tmp/codex-usage-menu-last-valid.json")

    private init() {
        latestSnapshot = Self.loadCachedSnapshot() ?? .empty
        client.onUpdate = { [weak self] rateLimits in
            self?.queue.async { [weak self] in
                self?.handleUpdateOnQueue(rateLimits)
            }
        }
        client.onError = { [weak self] error in
            self?.queue.async { [weak self] in
                self?.handleErrorOnQueue(error)
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.started else { return }
            self.started = true
            self.latestSnapshot = self.latestSnapshot.replacing(
                status: .syncing,
                statusDetail: "正在连接官方 App Server"
            )
            self.emitOnQueue(self.latestSnapshot)
            self.client.start()
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.started {
                self.started = true
                self.latestSnapshot = self.latestSnapshot.replacing(
                    status: .syncing,
                    statusDetail: "正在连接官方 App Server"
                )
                self.emitOnQueue(self.latestSnapshot)
                self.client.start()
            }
            self.markStaleIfNeededOnQueue()
            self.client.requestRateLimits(force: true)
        }
    }

    func stop() {
        queue.sync {
            guard started else { return }
            started = false
            client.stop()
        }
    }

    private func handleUpdateOnQueue(_ rateLimits: OfficialRateLimits) {
        let now = Date()
        latestSnapshot = UsageSnapshot(
            fiveHour: rateLimits.fiveHour,
            sevenDay: rateLimits.sevenDay,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            totalTokens: 0,
            modelContextWindow: nil,
            sourceFile: "official-app-server",
            eventDate: now,
            receivedAt: now,
            status: .current,
            statusDetail: "官方 App Server 已同步",
            tokenDataAvailable: false
        )
        Self.persist(rateLimits: rateLimits, receivedAt: now)
        emitOnQueue(latestSnapshot)
    }

    private func handleErrorOnQueue(_ error: Error) {
        let status: UsageSyncStatus
        let detail: String
        if let clientError = error as? OfficialUsageClientError,
           clientError == .authenticationRequired {
            status = latestSnapshot.receivedAt == nil ? .unavailable : .delayed
            detail = "官方 App Server 需要当前 Codex 登录态"
        } else if latestSnapshot.receivedAt == nil {
            status = .unavailable
            detail = "官方 App Server 暂不可用"
        } else {
            status = .delayed
            detail = "等待官方 App Server 更新"
        }
        latestSnapshot = latestSnapshot.replacing(status: status, statusDetail: detail)
        emitOnQueue(latestSnapshot)
    }

    private static func loadCachedSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fiveObject = object["fiveHour"] as? [String: Any],
              let sevenObject = object["sevenDay"] as? [String: Any],
              let fiveUsed = number(fiveObject["usedPercent"]),
              let sevenUsed = number(sevenObject["usedPercent"]),
              let receivedRaw = number(object["receivedAt"]) else {
            return nil
        }
        let fiveReset = number(fiveObject["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        let sevenReset = number(sevenObject["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        let receivedAt = Date(timeIntervalSince1970: receivedRaw)
        return UsageSnapshot(
            fiveHour: UsageWindow(usedPercent: fiveUsed, resetsAt: fiveReset),
            sevenDay: UsageWindow(usedPercent: sevenUsed, resetsAt: sevenReset),
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            totalTokens: 0,
            modelContextWindow: nil,
            sourceFile: "official-app-server-cache",
            eventDate: receivedAt,
            receivedAt: receivedAt,
            status: .syncing,
            statusDetail: "正在用最近一次官方快照同步",
            tokenDataAvailable: false
        )
    }

    private static func persist(rateLimits: OfficialRateLimits, receivedAt: Date) {
        func windowObject(_ window: UsageWindow) -> [String: Any] {
            var result: [String: Any] = [:]
            if let usedPercent = window.usedPercent {
                result["usedPercent"] = usedPercent
            }
            if let resetsAt = window.resetsAt {
                result["resetsAt"] = resetsAt.timeIntervalSince1970
            }
            return result
        }
        let object: [String: Any] = [
            "receivedAt": receivedAt.timeIntervalSince1970,
            "fiveHour": windowObject(rateLimits.fiveHour),
            "sevenDay": windowObject(rateLimits.sevenDay)
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return
        }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func markStaleIfNeededOnQueue() {
        guard let receivedAt = latestSnapshot.receivedAt else { return }
        let age = Date().timeIntervalSince(receivedAt)
        if age > 15 * 60 {
            latestSnapshot = latestSnapshot.replacing(
                status: .stale,
                statusDetail: "超过 15 分钟未收到官方更新"
            )
            emitOnQueue(latestSnapshot)
        } else if age > 2 * 60 {
            latestSnapshot = latestSnapshot.replacing(
                status: .delayed,
                statusDetail: "超过 2 分钟未收到官方更新"
            )
            emitOnQueue(latestSnapshot)
        }
    }

    private func emitOnQueue(_ snapshot: UsageSnapshot) {
        let callback = onSnapshot
        DispatchQueue.main.async {
            callback?(snapshot)
        }
    }
}
