import Cocoa
import Foundation

private struct UsageWindow {
    let usedPercent: Double?
    let resetsAt: Date?
}

private struct UsageSnapshot {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let modelContextWindow: Int?
    let sourceFile: String?
    let eventDate: Date?

    static let empty = UsageSnapshot(
        fiveHour: UsageWindow(usedPercent: nil, resetsAt: nil),
        sevenDay: UsageWindow(usedPercent: nil, resetsAt: nil),
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        totalTokens: 0,
        modelContextWindow: nil,
        sourceFile: nil,
        eventDate: nil
    )
}

private struct UsageEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

private struct CachedUsageFile {
    let modifiedAt: Date
    let fileSize: Int64
    let entries: [UsageEntry]
}

private final class UsageReader {
    private let sessionsDirectory: URL
    private let fileManager = FileManager.default
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let standardDateFormatter: ISO8601DateFormatter
    private var cache: [String: CachedUsageFile] = [:]

    init() {
        sessionsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standardDateFormatter = ISO8601DateFormatter()
    }

    func read() -> UsageSnapshot {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var newest: (date: Date, snapshot: UsageSnapshot)?
        var fiveHourAggregate: UsageWindow?
        var sevenDayAggregate: UsageWindow?
        let now = Date()
        let fiveHourCutoff = now.addingTimeInterval(-5 * 60 * 60)
        let sevenDayCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var seenPaths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  attributes.isRegularFile == true,
                  let modifiedAt = attributes.contentModificationDate,
                  let fileSize = attributes.fileSize else {
                continue
            }
            seenPaths.insert(url.path)

            let entries: [UsageEntry]
            if let cached = cache[url.path],
               cached.modifiedAt == modifiedAt,
               cached.fileSize == Int64(fileSize) {
                entries = cached.entries
            } else if let cached = cache[url.path],
                      Int64(fileSize) > cached.fileSize {
                let appended = parseEntries(from: url, tailBytes: 1_048_576)
                entries = mergeEntries(cached.entries, appended)
            } else {
                entries = parseEntries(from: url)
            }
            cache[url.path] = CachedUsageFile(
                modifiedAt: modifiedAt,
                fileSize: Int64(fileSize),
                entries: entries
            )

            for entry in entries {
                let snapshot = entry.snapshot
                if entry.date >= fiveHourCutoff,
                   isActive(window: snapshot.fiveHour, now: now) {
                    fiveHourAggregate = maxUsageWindow(fiveHourAggregate, snapshot.fiveHour)
                }
                if entry.date >= sevenDayCutoff,
                   isActive(window: snapshot.sevenDay, now: now) {
                    sevenDayAggregate = maxUsageWindow(sevenDayAggregate, snapshot.sevenDay)
                }
                if newest == nil || entry.date > newest!.date {
                    newest = (entry.date, snapshot)
                }
            }
        }

        cache = cache.filter { seenPaths.contains($0.key) }
        guard let newestSnapshot = newest?.snapshot else { return .empty }
        return UsageSnapshot(
            fiveHour: fiveHourAggregate ?? newestSnapshot.fiveHour,
            sevenDay: sevenDayAggregate ?? newestSnapshot.sevenDay,
            inputTokens: newestSnapshot.inputTokens,
            cachedInputTokens: newestSnapshot.cachedInputTokens,
            outputTokens: newestSnapshot.outputTokens,
            reasoningTokens: newestSnapshot.reasoningTokens,
            totalTokens: newestSnapshot.totalTokens,
            modelContextWindow: newestSnapshot.modelContextWindow,
            sourceFile: newestSnapshot.sourceFile,
            eventDate: newestSnapshot.eventDate
        )
    }

    private func parseEntries(from url: URL, tailBytes: Int? = nil) -> [UsageEntry] {
        guard let data = readData(from: url, tailBytes: tailBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var entries: [UsageEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let eventDate = parseDate(timestamp),
                  object["type"] as? String == "event_msg",
                  let tokenPayload = object["payload"] as? [String: Any],
                  tokenPayload["type"] as? String == "token_count",
                  let info = tokenPayload["info"] as? [String: Any] else {
                continue
            }

            let totalUsage = info["total_token_usage"] as? [String: Any] ?? [:]
            let rateLimits = tokenPayload["rate_limits"] as? [String: Any] ?? [:]
            let primary = rateLimits["primary"] as? [String: Any] ?? [:]
            let secondary = rateLimits["secondary"] as? [String: Any] ?? [:]
            let snapshot = UsageSnapshot(
                fiveHour: UsageWindow(
                    usedPercent: number(primary["used_percent"]),
                    resetsAt: dateFromEpoch(primary["resets_at"])
                ),
                sevenDay: UsageWindow(
                    usedPercent: number(secondary["used_percent"]),
                    resetsAt: dateFromEpoch(secondary["resets_at"])
                ),
                inputTokens: integer(totalUsage["input_tokens"]),
                cachedInputTokens: integer(totalUsage["cached_input_tokens"]),
                outputTokens: integer(totalUsage["output_tokens"]),
                reasoningTokens: integer(totalUsage["reasoning_output_tokens"]),
                totalTokens: integer(totalUsage["total_tokens"]),
                modelContextWindow: integerOrNil(info["model_context_window"]),
                sourceFile: url.path,
                eventDate: eventDate
            )
            entries.append(UsageEntry(date: eventDate, snapshot: snapshot))
        }
        return entries
    }

    private func mergeEntries(_ current: [UsageEntry], _ updates: [UsageEntry]) -> [UsageEntry] {
        var byDate: [TimeInterval: UsageEntry] = [:]
        byDate.reserveCapacity(current.count + updates.count)
        for entry in current {
            byDate[entry.date.timeIntervalSince1970] = entry
        }
        for entry in updates {
            byDate[entry.date.timeIntervalSince1970] = entry
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private func readData(from url: URL, tailBytes: Int?) -> Data? {
        guard let tailBytes else {
            return try? Data(contentsOf: url)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        if (try? handle.seek(toOffset: start)) == nil { return nil }
        guard let data = try? handle.readToEnd() else { return nil }
        guard start > 0 else { return data }
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return data.suffix(from: data.index(after: newline))
    }

    private func isActive(window: UsageWindow, now: Date) -> Bool {
        guard window.usedPercent != nil else { return false }
        // A missing reset timestamp is still useful as a fallback, but a timestamp in
        // the past definitively belongs to an expired quota window.
        return window.resetsAt == nil || window.resetsAt! > now
    }

    private func maxUsageWindow(_ current: UsageWindow?, _ candidate: UsageWindow) -> UsageWindow {
        guard let current else { return candidate }
        let currentUsed = current.usedPercent ?? -Double.infinity
        let candidateUsed = candidate.usedPercent ?? -Double.infinity
        return candidateUsed > currentUsed ? candidate : current
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int {
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func integerOrNil(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber else { return nil }
        return value.intValue
    }

    private func dateFromEpoch(_ value: Any?) -> Date? {
        guard let value = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }
}

private enum TaskStatus: Equatable {
    case running
    case waiting
    case completed
    case interrupted
    case idle

    var displayName: String {
        switch self {
        case .running: return "进行中"
        case .waiting: return "等待中"
        case .completed: return "已完成"
        case .interrupted: return "已中断"
        case .idle: return "空闲"
        }
    }

    var color: NSColor {
        switch self {
        case .running: return NSColor(calibratedRed: 0.10, green: 0.46, blue: 0.95, alpha: 1)
        case .waiting: return NSColor(calibratedRed: 0.92, green: 0.52, blue: 0.05, alpha: 1)
        case .completed: return NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.30, alpha: 1)
        case .interrupted: return NSColor(calibratedRed: 0.83, green: 0.15, blue: 0.17, alpha: 1)
        case .idle: return NSColor.secondaryLabelColor
        }
    }
}

private struct TaskProgress {
    let id: String
    let title: String
    let project: String
    let cwd: String
    let status: TaskStatus
    let lastActivity: Date
    let startedAt: Date?
    let finishedAt: Date?
    let lastEvent: String
    let detail: String
    let model: String?
    let sourceFile: String
    let isSubagent: Bool
    let completedSteps: Int?
    let totalSteps: Int?
    let currentStep: String?

    var elapsed: TimeInterval {
        guard let start = startedAt else { return 0 }
        let end = finishedAt ?? Date()
        return max(0, end.timeIntervalSince(start))
    }
}

private struct CachedTask {
    let modifiedAt: Date
    let fileSize: Int64
    let task: TaskProgress
}

private final class TaskReader {
    private let sessionsDirectory: URL
    private let sessionIndexURL: URL
    private let fileManager = FileManager.default
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let standardDateFormatter: ISO8601DateFormatter
    private var cache: [String: CachedTask] = [:]
    private var ignoredFiles: [String: (modifiedAt: Date, fileSize: Int64)] = [:]
    private var threadNames: [String: String] = [:]
    private var sessionIndexModifiedAt: Date?

    init() {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        sessionsDirectory = codexDirectory
            .appendingPathComponent("sessions", isDirectory: true)
        sessionIndexURL = codexDirectory.appendingPathComponent("session_index.jsonl")
        fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standardDateFormatter = ISO8601DateFormatter()
    }

    func read(limit: Int = 20) -> [TaskProgress] {
        refreshThreadNamesIfNeeded()
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var tasksByID: [String: TaskProgress] = [:]
        var seenPaths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let fileSize = values.fileSize else {
                continue
            }
            seenPaths.insert(url.path)
            guard let task = task(for: url, modifiedAt: modifiedAt, fileSize: Int64(fileSize)) else {
                continue
            }
            if let existing = tasksByID[task.id] {
                if task.lastActivity > existing.lastActivity {
                    tasksByID[task.id] = task
                }
            } else {
                tasksByID[task.id] = task
            }
        }

        cache = cache.filter { seenPaths.contains($0.key) }
        ignoredFiles = ignoredFiles.filter { seenPaths.contains($0.key) }
        var tasks = Array(tasksByID.values)
        tasks.sort {
            statusPriority($0.status) != statusPriority($1.status)
                ? statusPriority($0.status) < statusPriority($1.status)
                : $0.lastActivity > $1.lastActivity
        }
        return Array(tasks.prefix(limit))
    }

    private func task(for url: URL, modifiedAt: Date, fileSize: Int64) -> TaskProgress? {
        if let ignored = ignoredFiles[url.path],
           ignored.modifiedAt == modifiedAt,
           ignored.fileSize == fileSize {
            return nil
        }
        if let cached = cache[url.path], cached.modifiedAt == modifiedAt, cached.fileSize == fileSize {
            return cached.task
        }
        if let cached = cache[url.path],
           fileSize >= cached.fileSize,
           cached.fileSize >= 1_048_576 {
            let task = taskFromTail(
                url: url,
                modifiedAt: modifiedAt,
                cached: cached.task
            )
            cache[url.path] = CachedTask(modifiedAt: modifiedAt, fileSize: fileSize, task: task)
            return task
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var source = ""
        var threadSource = ""
        var parentThreadID: String?
        var firstUserText: String?
        var firstUserDate: Date?
        var latestUserText: String?
        var latestUserDate: Date?
        var latestActivity = modifiedAt
        var latestEvent = "读取日志"
        var latestDetail: String?
        var latestStart: Date?
        var latestComplete: Date?
        var latestTerminal: Date?
        var latestTerminalStatus: TaskStatus?
        var latestModel: String?
        var planCounts: (completed: Int, total: Int, current: String?)?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let date = (object["timestamp"] as? String).flatMap(parseDate) ?? modifiedAt
            if date > latestActivity { latestActivity = date }

            let objectType = object["type"] as? String ?? ""
            if objectType == "session_meta", let payload = object["payload"] as? [String: Any] {
                sessionID = (payload["id"] as? String) ?? sessionID
                cwd = (payload["cwd"] as? String) ?? cwd
                source = (payload["source"] as? String) ?? source
                threadSource = (payload["thread_source"] as? String) ?? threadSource
                parentThreadID = payload["parent_thread_id"] as? String
                continue
            }

            if objectType == "event_msg", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                switch payloadType {
                case "task_started":
                    latestStart = date
                    latestEvent = "任务开始"
                    latestDetail = "开始处理"
                case "task_complete":
                    latestComplete = date
                    latestTerminal = date
                    latestTerminalStatus = .completed
                    latestEvent = "任务完成"
                    latestDetail = "已完成全部步骤"
                case "turn_aborted":
                    latestTerminal = date
                    latestTerminalStatus = .interrupted
                    latestEvent = "任务中断"
                    latestDetail = "任务被中断"
                case "item_completed":
                    if let item = payload["item"] as? [String: Any] {
                        let itemType = item["type"] as? String ?? ""
                        latestEvent = eventLabel(for: itemType)
                        latestDetail = eventDetail(from: item) ?? latestEvent
                        if itemType == "UserMessage", let message = userText(from: item), !message.isEmpty {
                            let cleaned = cleanTitle(message)
                            if !cleaned.isEmpty && !isGenericTitle(cleaned), firstUserText == nil {
                                firstUserText = message
                                firstUserDate = date
                            }
                            if !cleaned.isEmpty && !isGenericTitle(cleaned) {
                                latestUserText = message
                                latestUserDate = date
                            }
                        }
                        if let counts = findPlan(in: item) { planCounts = counts }
                    }
                case "thread_settings_applied":
                    if let settings = payload["thread_settings"] as? [String: Any] {
                        latestModel = settings["model"] as? String ?? latestModel
                    }
                    latestEvent = "更新设置"
                    latestDetail = "更新模型与设置"
                default:
                    latestEvent = eventLabel(for: payloadType)
                }
                if let counts = findPlan(in: payload) { planCounts = counts }
            } else if objectType == "response_item", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                latestEvent = eventLabel(for: payloadType)
                latestDetail = eventDetail(from: payload) ?? latestEvent
                if payloadType == "message", payload["role"] as? String == "user",
                   let message = userText(from: payload), !message.isEmpty {
                    let cleaned = cleanTitle(message)
                    if !cleaned.isEmpty && !isGenericTitle(cleaned), firstUserText == nil {
                        firstUserText = message
                        firstUserDate = date
                    }
                    if !cleaned.isEmpty && !isGenericTitle(cleaned) {
                        latestUserText = message
                        latestUserDate = date
                    }
                }
                if let counts = findPlan(in: payload) { planCounts = counts }
            } else if objectType == "turn_context", let payload = object["payload"] as? [String: Any] {
                latestModel = (payload["model"] as? String) ?? latestModel
            }

            if objectType == "event_msg", let payload = object["payload"] as? [String: Any],
               let counts = findPlan(in: payload) {
                planCounts = counts
            }
        }

        // Internal review runs are implementation details, not user-facing tasks.
        if threadSource == "guardian_review" || source == "guardian_review" {
            ignoredFiles[url.path] = (modifiedAt: modifiedAt, fileSize: fileSize)
            return nil
        }
        let terminalDate = latestTerminal
        let status: TaskStatus
        if let start = latestStart, terminalDate == nil || (terminalDate != nil && start > terminalDate!) {
            status = .running
        } else if latestTerminalStatus == .interrupted {
            status = .interrupted
        } else if latestComplete != nil {
            status = .completed
        } else if let userDate = latestUserDate, userDate >= (terminalDate ?? .distantPast) {
            status = Date().timeIntervalSince(userDate) < 15 * 60 ? .waiting : .idle
        } else {
            status = Date().timeIntervalSince(latestActivity) < 15 * 60 ? .waiting : .idle
        }

        let indexedTitle = threadNames[sessionID] ?? (parentThreadID.flatMap { threadNames[$0] })
        let title = cleanTitle(indexedTitle ?? latestUserText ?? firstUserText ?? "未命名任务")
        let project = cwd.isEmpty ? "当前工作区" : URL(fileURLWithPath: cwd).lastPathComponent
        let task = TaskProgress(
            id: sessionID,
            title: title.isEmpty ? "未命名任务" : title,
            project: project.isEmpty ? "当前工作区" : project,
            cwd: cwd,
            status: status,
            lastActivity: latestActivity,
            startedAt: latestStart ?? firstUserDate,
            finishedAt: terminalDate,
            lastEvent: latestEvent,
            detail: planCounts?.current ?? latestDetail ?? latestEvent,
            model: latestModel,
            sourceFile: url.path,
            isSubagent: parentThreadID != nil,
            completedSteps: planCounts?.completed,
            totalSteps: planCounts?.total,
            currentStep: planCounts?.current
        )
        cache[url.path] = CachedTask(modifiedAt: modifiedAt, fileSize: fileSize, task: task)
        return task
    }

    private func taskFromTail(url: URL, modifiedAt: Date, cached: TaskProgress) -> TaskProgress {
        guard let data = readTailData(from: url, maxBytes: 1_048_576),
              let text = String(data: data, encoding: .utf8) else {
            return cached
        }

        var latestActivity = max(cached.lastActivity, modifiedAt)
        var latestEvent = cached.lastEvent
        var latestDetail = cached.detail
        var latestStart = cached.startedAt
        var latestComplete: Date? = cached.status == .completed ? cached.finishedAt : nil
        var latestTerminal = cached.finishedAt
        var latestTerminalStatus: TaskStatus?
        if cached.status == .completed { latestTerminalStatus = .completed }
        if cached.status == .interrupted { latestTerminalStatus = .interrupted }
        var latestUserDate: Date?
        var latestModel = cached.model
        var planCounts: (completed: Int, total: Int, current: String?)?
        if let completed = cached.completedSteps, let total = cached.totalSteps {
            planCounts = (completed, total, cached.currentStep)
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let date = (object["timestamp"] as? String).flatMap(parseDate) ?? modifiedAt
            if date > latestActivity { latestActivity = date }
            let objectType = object["type"] as? String ?? ""

            if objectType == "event_msg", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                switch payloadType {
                case "task_started":
                    latestStart = date
                    latestEvent = "任务开始"
                    latestDetail = "开始处理"
                case "task_complete":
                    latestComplete = date
                    latestTerminal = date
                    latestTerminalStatus = .completed
                    latestEvent = "任务完成"
                    latestDetail = "已完成全部步骤"
                case "turn_aborted":
                    latestTerminal = date
                    latestTerminalStatus = .interrupted
                    latestEvent = "任务中断"
                    latestDetail = "任务被中断"
                case "item_completed":
                    if let item = payload["item"] as? [String: Any] {
                        let itemType = item["type"] as? String ?? ""
                        latestEvent = eventLabel(for: itemType)
                        if let detail = eventDetail(from: item) {
                            latestDetail = detail
                        }
                        if itemType == "UserMessage", let message = userText(from: item), !message.isEmpty {
                            let cleaned = cleanTitle(message)
                            if !cleaned.isEmpty && !isGenericTitle(cleaned) {
                                latestUserDate = date
                            }
                        }
                        if let counts = findPlan(in: item) { planCounts = counts }
                    }
                case "thread_settings_applied":
                    if let settings = payload["thread_settings"] as? [String: Any] {
                        latestModel = settings["model"] as? String ?? latestModel
                    }
                    latestEvent = "更新设置"
                    latestDetail = "更新模型与设置"
                default:
                    latestEvent = eventLabel(for: payloadType)
                }
                if let counts = findPlan(in: payload) { planCounts = counts }
            } else if objectType == "response_item", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                latestEvent = eventLabel(for: payloadType)
                if let detail = eventDetail(from: payload) {
                    latestDetail = detail
                }
                if payloadType == "message", payload["role"] as? String == "user",
                   let message = userText(from: payload), !message.isEmpty {
                    let cleaned = cleanTitle(message)
                    if !cleaned.isEmpty && !isGenericTitle(cleaned) {
                        latestUserDate = date
                    }
                }
                if let counts = findPlan(in: payload) { planCounts = counts }
            } else if objectType == "turn_context", let payload = object["payload"] as? [String: Any] {
                latestModel = (payload["model"] as? String) ?? latestModel
            }
        }

        let status: TaskStatus
        if let start = latestStart, latestTerminal == nil || (latestTerminal != nil && start > latestTerminal!) {
            status = .running
        } else if latestTerminalStatus == .interrupted {
            status = .interrupted
        } else if latestComplete != nil {
            status = .completed
        } else if let userDate = latestUserDate, userDate >= (latestTerminal ?? .distantPast) {
            status = Date().timeIntervalSince(userDate) < 15 * 60 ? .waiting : .idle
        } else if cached.status == .waiting {
            status = Date().timeIntervalSince(cached.lastActivity) < 15 * 60 ? .waiting : .idle
        } else {
            status = cached.status
        }

        return TaskProgress(
            id: cached.id,
            title: threadNames[cached.id] ?? cached.title,
            project: cached.project,
            cwd: cached.cwd,
            status: status,
            lastActivity: latestActivity,
            startedAt: latestStart,
            finishedAt: latestTerminal,
            lastEvent: latestEvent,
            detail: planCounts?.current ?? latestDetail,
            model: latestModel,
            sourceFile: cached.sourceFile,
            isSubagent: cached.isSubagent,
            completedSteps: planCounts?.completed ?? cached.completedSteps,
            totalSteps: planCounts?.total ?? cached.totalSteps,
            currentStep: planCounts?.current ?? cached.currentStep
        )
    }

    private func readTailData(from url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        if (try? handle.seek(toOffset: start)) == nil { return nil }
        guard let data = try? handle.readToEnd() else { return nil }
        guard start > 0 else { return data }
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return Data(data.suffix(from: data.index(after: newline)))
    }

    private func refreshThreadNamesIfNeeded() {
        guard let values = try? sessionIndexURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return
        }
        if modifiedAt == sessionIndexModifiedAt { return }

        guard let data = try? Data(contentsOf: sessionIndexURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        struct IndexedName {
            let name: String
            let updatedAt: Date
        }
        var latest: [String: IndexedName] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = object["id"] as? String,
                  let rawName = object["thread_name"] as? String else {
                continue
            }
            let name = cleanTitle(rawName)
            guard !name.isEmpty else { continue }
            let updatedAt = (object["updated_at"] as? String).flatMap(parseDate) ?? .distantPast
            if let current = latest[id], current.updatedAt >= updatedAt { continue }
            latest[id] = IndexedName(name: name, updatedAt: updatedAt)
        }
        threadNames = latest.mapValues(\.name)
        sessionIndexModifiedAt = modifiedAt
    }

    private func statusPriority(_ status: TaskStatus) -> Int {
        switch status {
        case .running: return 0
        case .waiting: return 1
        case .interrupted: return 2
        case .idle: return 3
        case .completed: return 4
        }
    }

    private func eventLabel(for type: String) -> String {
        switch type {
       case "AgentMessage", "message": return "输出结果"
        case "CommandExecution", "function_call", "function_call_output": return "执行命令"
        case "custom_tool_call", "custom_tool_result": return "调用工具"
        case "custom_tool_call_output": return "工具返回"
        case "McpToolCall": return "调用工具"
        case "FileChange": return "修改文件"
        case "Reasoning": return "思考中"
        case "ContextCompaction": return "整理上下文"
        case "task_started": return "任务开始"
        case "task_complete": return "任务完成"
        case "turn_aborted": return "任务中断"
        case "token_count": return "更新用量"
        default: return type.isEmpty ? "更新任务" : type
        }
    }

    private func eventDetail(from object: [String: Any]) -> String? {
        let type = object["type"] as? String ?? ""
        if type == "CommandExecution", let command = object["command"] as? [String] {
            return compactText(command.joined(separator: " "), limit: 38)
        }
        if type == "McpToolCall", let name = object["name"] as? String {
            return compactText(name, limit: 38)
        }
        if type == "custom_tool_call", let name = object["name"] as? String {
            return compactText(name, limit: 38)
        }
        if type == "custom_tool_call_output" { return "工具返回结果" }
        if type == "Reasoning", let summary = object["summary_text"] as? [String], let first = summary.first {
            return compactText(first, limit: 38)
        }
        if type == "FileChange" { return "修改文件" }
        if type == "AgentMessage", let text = userText(from: object) {
            let cleaned = cleanTitle(text)
            return cleaned.isEmpty ? nil : compactText(cleaned, limit: 38)
        }
        if type == "message", let name = object["name"] as? String {
            return compactText(name, limit: 38)
        }
        return nil
    }

    private func compactText(_ value: String, limit: Int) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    private func userText(from object: [String: Any]) -> String? {
        if let text = object["text"] as? String { return text }
        for key in ["content", "parts", "input"] {
            if let value = object[key], let text = textValue(from: value), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func textValue(from value: Any, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }
        if let text = value as? String { return text }
        if let array = value as? [Any] {
            let pieces = array.compactMap { textValue(from: $0, depth: depth + 1) }
            let result = pieces.joined(separator: " ")
            return result.isEmpty ? nil : result
        }
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String { return text }
            for key in ["content", "parts", "input"] {
                if let child = dictionary[key], let text = textValue(from: child, depth: depth + 1), !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func cleanTitle(_ value: String) -> String {
        var text = value
        while let start = text.range(of: "<environment_context>"),
              let end = text.range(of: "</environment_context>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var lines: [String] = []
        var inCodeFence = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence || line.isEmpty || line.hasPrefix("# Files mentioned") ||
                line.hasPrefix("<image") || line.contains("Distinguish instructions") ||
                line.contains("path=\"") {
                continue
            }
            lines.append(line)
        }
        let result = lines.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > 56 ? String(result.prefix(56)) + "…" : result
    }

    private func isGenericTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["做吧", "继续", "好的", "好", "可以", "开始", "嗯", "ok", "okay"].contains(normalized)
    }

    private func findPlan(in value: Any, depth: Int = 0) -> (completed: Int, total: Int, current: String?)? {
        guard depth < 6 else { return nil }
        if let array = value as? [Any] {
            let dictionaries = array.compactMap { $0 as? [String: Any] }
            let entries = dictionaries.filter { dictionary in
                guard let status = (dictionary["status"] as? String)?.lowercased() else { return false }
                return ["completed", "complete", "done", "in_progress", "in-progress", "pending", "not_started"].contains(status)
                    && (dictionary["step"] != nil || dictionary["name"] != nil || dictionary["label"] != nil || dictionary["text"] != nil)
            }
            if !entries.isEmpty && entries.count == dictionaries.count {
                let completed = entries.filter {
                    let status = (($0["status"] as? String) ?? "").lowercased()
                    return ["completed", "complete", "done"].contains(status)
                }.count
                let current = entries.first {
                    let status = (($0["status"] as? String) ?? "").lowercased()
                    return ["in_progress", "in-progress"].contains(status)
                }.flatMap { $0["step"] as? String ?? $0["name"] as? String ?? $0["label"] as? String }
                return (completed, entries.count, current)
            }
            for child in array {
                if let result = findPlan(in: child, depth: depth + 1) { return result }
            }
        } else if let dictionary = value as? [String: Any] {
            for child in dictionary.values {
                if let result = findPlan(in: child, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
    }
}

private final class TaskPanelView: NSView {
    private struct HitRow {
        let frame: NSRect
        let task: TaskProgress?
        let moreTitle: String?
        let moreTasks: [TaskProgress]
    }

    var tasks: [TaskProgress] = [] {
        didSet {
            resizeForContent()
            needsDisplay = true
        }
    }
    var onSelect: ((TaskProgress) -> Void)?
    var onShowMore: ((String, [TaskProgress]) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hitRows: [HitRow] = []

    private let rowHeight: CGFloat = 24
    private let sectionHeaderHeight: CGFloat = 16

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        background.lineWidth = 1
        background.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        drawText("Codex 任务进度", in: NSRect(x: 10, y: 5, width: bounds.width - 20, height: 15), attributes: titleAttributes)

        let active = sortedTasks(statuses: [.running, .waiting])
        let finished = sortedTasks(statuses: [.completed, .interrupted, .idle])
        hitRows = []
        var y: CGFloat = 22
        drawSection("进行中", tasks: active, y: &y)
        drawSection("已完成", tasks: finished, y: &y)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let match = hitRows.first(where: { $0.frame.contains(point) }) {
            if let task = match.task {
                onSelect?(task)
            } else if let title = match.moreTitle {
                onShowMore?(title, match.moreTasks)
            }
        }
    }

    private func drawSection(_ title: String, tasks: [TaskProgress], y: inout CGFloat) {
        let sectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        drawText("\(title) \(tasks.count)", in: NSRect(x: 10, y: y, width: bounds.width - 20, height: 15), attributes: sectionAttributes)
        y += sectionHeaderHeight

        guard let firstTask = tasks.first else {
            let emptyAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            drawText("暂无任务", in: NSRect(x: 22, y: y + 5, width: bounds.width - 30, height: 13), attributes: emptyAttributes)
            y += rowHeight + 1
            return
        }
        drawTaskRow(firstTask, y: &y)

        if tasks.count > 1 {
            let remainingTasks = Array(tasks.dropFirst())
            let rowFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            hitRows.append(HitRow(
                frame: rowFrame,
                task: nil,
                moreTitle: title,
                moreTasks: remainingTasks
            ))
            let moreAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor
            ]
            drawText("更多 \(remainingTasks.count) 项", in: NSRect(x: 22, y: y + 5, width: bounds.width - 30, height: 14), attributes: moreAttributes)
            y += rowHeight
        }
        y += 1
    }

    private func drawTaskRow(_ task: TaskProgress, y: inout CGFloat) {
        let rowFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
        hitRows.append(HitRow(frame: rowFrame, task: task, moreTitle: nil, moreTasks: []))
        task.status.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 10, y: y + 5, width: 6, height: 6)).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.8, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        drawText(task.title, in: NSRect(x: 22, y: y - 1, width: bounds.width - 30, height: 13), attributes: titleAttributes)

        var detail = task.detail
        if task.status != .running && task.status != .waiting {
            detail = "\(task.status.displayName) · \(detail)"
        }
        if let completed = task.completedSteps, let total = task.totalSteps, total > 0 {
            detail += " · \(completed)/\(total)"
        }
        detail += " · \(formatElapsed(task.elapsed))"
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        drawText(detail, in: NSRect(x: 22, y: y + 11, width: bounds.width - 30, height: 12), attributes: detailAttributes)
        y += rowHeight
    }

    private func resizeForContent() {
        let active = tasks.filter { $0.status == .running || $0.status == .waiting }
        let finished = tasks.filter { $0.status != .running && $0.status != .waiting }
        var contentHeight: CGFloat = 22
        for count in [active.count, finished.count] {
            let visibleRows = count == 0 ? 1 : (count > 1 ? 2 : 1)
            contentHeight += sectionHeaderHeight + CGFloat(visibleRows) * rowHeight + 1
        }
        let requiredHeight = max(165, contentHeight + 1)
        if abs(frame.height - requiredHeight) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: requiredHeight))
        }
    }

    private func sortedTasks(statuses: [TaskStatus]) -> [TaskProgress] {
        tasks
            .filter { task in statuses.contains { $0 == task.status } }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func drawText(_ value: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var drawingAttributes = attributes
        drawingAttributes[.paragraphStyle] = paragraph
        (value as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: drawingAttributes,
            context: nil
        )
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分" }
        return "\(seconds / 3600)时\(seconds % 3600 / 60)分"
    }
}

private final class TaskDetailView: NSView {
    var tasks: [TaskProgress] = [] {
        didSet {
            resizeForContent()
            needsDisplay = true
        }
    }
    var onSelect: ((TaskProgress) -> Void)?
    private var hitRows: [(frame: NSRect, task: TaskProgress)] = []
    private let rowHeight: CGFloat = 46

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        drawText("剩余任务 \(tasks.count) 项", in: NSRect(x: 14, y: 12, width: bounds.width - 28, height: 16), attributes: headerAttributes)

        hitRows = []
        var y: CGFloat = 36
        for task in tasks {
            let rowFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            hitRows.append((rowFrame, task))
            task.status.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: y + 8, width: 7, height: 7)).fill()

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            drawText(task.title, in: NSRect(x: 29, y: y + 2, width: bounds.width - 43, height: 15), attributes: titleAttributes)

            var detail = task.detail
            if task.status != .running && task.status != .waiting {
                detail = "\(task.status.displayName) · \(detail)"
            }
            if let completed = task.completedSteps, let total = task.totalSteps, total > 0 {
                detail += " · \(completed)/\(total)"
            }
            detail += " · \(formatElapsed(task.elapsed))"
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            drawText(detail, in: NSRect(x: 29, y: y + 20, width: bounds.width - 43, height: 14), attributes: detailAttributes)
            y += rowHeight
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let match = hitRows.first(where: { $0.frame.contains(point) }) {
            onSelect?(match.task)
        }
    }

    private func resizeForContent() {
        let requiredHeight = max(72, 36 + CGFloat(tasks.count) * rowHeight + 8)
        if abs(frame.height - requiredHeight) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: requiredHeight))
        }
    }

    private func drawText(_ value: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var drawingAttributes = attributes
        drawingAttributes[.paragraphStyle] = paragraph
        (value as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: drawingAttributes,
            context: nil
        )
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分" }
        return "\(seconds / 3600)时\(seconds % 3600 / 60)分"
    }
}

private final class TaskDetailWindowController: NSWindowController, NSWindowDelegate {
    private let detailView: TaskDetailView
    private let scrollView: NSScrollView
    private let windowWidth: CGFloat = 360
    private weak var parentWindow: NSWindow?
    private var autoCloseTimer: Timer?
    private var autoCloseNotBefore = Date.distantFuture
    var onSelect: ((TaskProgress) -> Void)?

    init(sectionTitle: String, tasks: [TaskProgress]) {
        let size = NSSize(width: 360, height: 260)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(sectionTitle) · 更多任务"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        detailView = TaskDetailView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        detailView.tasks = tasks
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = detailView
        panel.contentView = scrollView
        super.init(window: panel)
        panel.delegate = self
        detailView.onSelect = { [weak self] task in
            self?.onSelect?(task)
        }
        update(tasks: tasks)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(tasks: [TaskProgress]) {
        detailView.tasks = tasks
        let contentHeight = max(72, 36 + CGFloat(tasks.count) * 46 + 8)
        let visibleHeight = min(520, max(160, contentHeight + 24))
        // Keep the popover compact. Reading the current content width here can
        // inherit a stale full-screen width after a resize, which made this
        // window unexpectedly stretch across the desktop.
        detailView.setFrameSize(NSSize(width: windowWidth, height: contentHeight))
        window?.setContentSize(NSSize(width: windowWidth, height: visibleHeight))
    }

    func show(relativeTo parent: NSWindow?) {
        parentWindow = parent
        if let parent, let detailWindow = window {
            let parentFrame = parent.frame
            let size = detailWindow.frame.size
            let x = max(12, parentFrame.minX - size.width - 12)
            let y = min(
                NSScreen.main?.visibleFrame.maxY ?? parentFrame.maxY,
                parentFrame.maxY
            ) - size.height
            detailWindow.setFrameOrigin(NSPoint(x: x, y: max(12, y)))
        }
        window?.orderFrontRegardless()
        startAutoCloseMonitor()
    }

    func hide() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        autoCloseNotBefore = .distantFuture
        parentWindow = nil
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    deinit {
        autoCloseTimer?.invalidate()
    }

    private func startAutoCloseMonitor() {
        autoCloseTimer?.invalidate()
        autoCloseNotBefore = Date().addingTimeInterval(0.7)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.closeIfPointerLeftBothWindows()
        }
        autoCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func closeIfPointerLeftBothWindows() {
        guard let detailWindow = window, detailWindow.isVisible else { return }
        guard Date() >= autoCloseNotBefore else { return }

        let mouseLocation = NSEvent.mouseLocation
        let detailFrame = detailWindow.frame.insetBy(dx: -2, dy: -2)
        let parentFrame = parentWindow?.frame.insetBy(dx: -2, dy: -2)
        if !detailFrame.contains(mouseLocation) && !(parentFrame?.contains(mouseLocation) ?? false) {
            hide()
        }
    }
}

private final class TaskPanelController: NSWindowController {
    private let taskView: TaskPanelView
    private var detailWindows: [String: TaskDetailWindowController] = [:]

    init() {
        // 180 × 165 is approximately one quarter of the previous window area.
        let size = NSSize(width: 180, height: 165)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screenFrame.maxX - size.width - 18, y: screenFrame.maxY - size.height - 18)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex 任务进度"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.68
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        taskView = TaskPanelView(frame: NSRect(origin: .zero, size: size))
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = taskView
        panel.contentView = scrollView
        super.init(window: panel)
        taskView.onHover = { [weak panel] hovering in
            panel?.alphaValue = hovering ? 1.0 : 0.68
        }
        taskView.onSelect = { task in
            Self.openTask(task)
        }
        taskView.onShowMore = { [weak self] sectionTitle, tasks in
            self?.showMore(sectionTitle: sectionTitle, tasks: tasks)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(tasks: [TaskProgress]) {
        taskView.tasks = tasks
        let active = tasks
            .filter { $0.status == .running || $0.status == .waiting }
            .sorted { $0.lastActivity > $1.lastActivity }
        let finished = tasks
            .filter { $0.status != .running && $0.status != .waiting }
            .sorted { $0.lastActivity > $1.lastActivity }
        updateDetailWindow(named: "进行中", tasks: Array(active.dropFirst()))
        updateDetailWindow(named: "已完成", tasks: Array(finished.dropFirst()))
    }

    func showPanel() {
        window?.orderFrontRegardless()
    }

    func hidePanel() {
        window?.orderOut(nil)
    }

    private func showMore(sectionTitle: String, tasks: [TaskProgress]) {
        guard !tasks.isEmpty else { return }
        let controller: TaskDetailWindowController
        if let existing = detailWindows[sectionTitle] {
            controller = existing
        } else {
            controller = TaskDetailWindowController(sectionTitle: sectionTitle, tasks: tasks)
            controller.onSelect = { task in
                Self.openTask(task)
            }
            detailWindows[sectionTitle] = controller
        }
        controller.update(tasks: tasks)
        controller.show(relativeTo: window)
    }

    private func updateDetailWindow(named sectionTitle: String, tasks: [TaskProgress]) {
        guard let controller = detailWindows[sectionTitle] else { return }
        if tasks.isEmpty {
            controller.hide()
        } else {
            controller.update(tasks: tasks)
        }
    }

    private static func openTask(_ task: TaskProgress) {
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        if let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.sourceFile)])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reader = UsageReader()
    private let taskReader = TaskReader()
    private let usageQueue = DispatchQueue(label: "local.codex.usage-menu.usage-reader")
    private let taskQueue = DispatchQueue(label: "local.codex.usage-menu.task-reader")
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer!
    private var taskRefreshTimer: Timer!
    private var latestSnapshot = UsageSnapshot.empty
    private var latestTasks: [TaskProgress] = []
    private var taskPanel: TaskPanelController!
    private var taskPanelVisible = true
    private var usageRefreshInFlight = false
    private var taskRefreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = NSMenu()

        taskPanel = TaskPanelController()
        taskPanel.showPanel()
        refresh()
        refreshTasks()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        taskRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshTasks()
        }
    }

    private func refresh() {
        guard !usageRefreshInFlight else { return }
        usageRefreshInFlight = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.reader.read()
            DispatchQueue.main.async {
                self.latestSnapshot = snapshot
                self.statusItem.button?.attributedTitle = self.title(for: snapshot)
                self.statusItem.button?.toolTip = self.tooltip(for: snapshot)
                self.rebuildMenu(for: snapshot)
                self.usageRefreshInFlight = false
            }
        }
    }

    private func refreshTasks() {
        guard !taskRefreshInFlight else { return }
        taskRefreshInFlight = true
        taskQueue.async { [weak self] in
            guard let self else { return }
            let tasks = self.taskReader.read()
            DispatchQueue.main.async {
                let taskCountChanged = self.latestTasks.count != tasks.count
                self.latestTasks = tasks
                self.taskPanel.update(tasks: tasks)
                self.taskRefreshInFlight = false
                self.statusItem.button?.toolTip = self.tooltip(for: self.latestSnapshot)
                if taskCountChanged {
                    self.rebuildMenu(for: self.latestSnapshot)
                }
            }
        }
    }

    private func title(for snapshot: UsageSnapshot) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        let result = NSMutableAttributedString(string: "Codex ", attributes: baseAttributes)
        appendRemainingSegment(to: result, label: "5h", window: snapshot.fiveHour, baseAttributes: baseAttributes)
        result.append(NSAttributedString(string: " · ", attributes: baseAttributes))
        appendRemainingSegment(to: result, label: "7d", window: snapshot.sevenDay, baseAttributes: baseAttributes)
        return result
    }

    private func appendRemainingSegment(
        to result: NSMutableAttributedString,
        label: String,
        window: UsageWindow,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        guard let remaining = remainingPercent(for: window) else {
            result.append(NSAttributedString(string: "\(label) —%", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color(forRemainingPercent: remaining)
        ]
        result.append(NSAttributedString(string: "\(label) \(formatPercent(remaining))%", attributes: attributes))
    }

    private func tooltip(for snapshot: UsageSnapshot) -> String {
        let five = remainingPercent(for: snapshot.fiveHour).map { "\(formatPercent($0))%" } ?? "暂无数据"
        let seven = remainingPercent(for: snapshot.sevenDay).map { "\(formatPercent($0))%" } ?? "暂无数据"
        let active = latestTasks.filter { $0.status == .running || $0.status == .waiting }.count
        return "Codex 剩余用量：5 小时 \(five)，7 天 \(seven)；\(active) 个活跃任务"
    }

    private func rebuildMenu(for snapshot: UsageSnapshot) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Codex 用量（本机日志）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let taskToggle = NSMenuItem(title: taskPanelVisible ? "隐藏任务窗口" : "显示任务窗口", action: #selector(toggleTaskPanel), keyEquivalent: "t")
        taskToggle.target = self
        menu.addItem(taskToggle)
        menu.addItem(infoItem("任务列表", value: "\(latestTasks.count) 个（每 4 秒刷新）"))
        menu.addItem(.separator())

        menu.addItem(infoItem("5 小时窗口", value: windowDescription(snapshot.fiveHour)))
        menu.addItem(infoItem("7 天窗口", value: windowDescription(snapshot.sevenDay)))
        menu.addItem(.separator())
        menu.addItem(infoItem("当前会话输入", value: formatTokens(snapshot.inputTokens)))
        menu.addItem(infoItem("其中缓存输入", value: formatTokens(snapshot.cachedInputTokens)))
        menu.addItem(infoItem("当前会话输出", value: formatTokens(snapshot.outputTokens)))
        menu.addItem(infoItem("推理 tokens", value: formatTokens(snapshot.reasoningTokens)))
        menu.addItem(infoItem("当前会话合计", value: formatTokens(snapshot.totalTokens)))
        if let context = snapshot.modelContextWindow {
            menu.addItem(infoItem("上下文窗口", value: formatTokens(context)))
        }
        menu.addItem(infoItem("最后事件", value: snapshot.eventDate.map(formatDate) ?? "暂无数据"))
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出监控", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func infoItem(_ label: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label)：\(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func windowDescription(_ window: UsageWindow) -> String {
        let remaining = remainingPercent(for: window).map { "\(formatPercent($0))%" } ?? "暂无数据"
        let used = window.usedPercent.map { "\(formatPercent($0))%" } ?? "暂无数据"
        guard let reset = window.resetsAt else {
            return "剩余 \(remaining)（已用 \(used)）"
        }
        return "剩余 \(remaining)（已用 \(used)），约 " + formatDate(reset) + " 重置"
    }

    private func remainingPercent(for window: UsageWindow) -> Double? {
        guard let used = window.usedPercent else { return nil }
        return max(0, min(100, 100 - used))
    }

    private func color(forRemainingPercent value: Double) -> NSColor {
        // Use dark colors on a light menu bar and bright colors on a dark menu bar.
        // A single fixed palette cannot provide strong contrast against both.
        if value >= 50 {
            return adaptiveColor(
                light: (0.00, 0.42, 0.18), // #006B2E
                dark: (0.15, 0.91, 0.47)   // #27E878
            )
        }
        if value >= 20 {
            return adaptiveColor(
                light: (0.55, 0.42, 0.00), // #8C6B00 — dark golden yellow on light backgrounds
                dark: (1.00, 0.82, 0.25)   // #FFD23F
            )
        }
        return adaptiveColor(
            light: (0.70, 0.12, 0.16), // #B21F29 — clear red without a purple cast
            dark: (1.00, 0.35, 0.37)   // #FF5A5F
        )
    }

    private func adaptiveColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            let rgb = match == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
        })
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    private func formatTokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    @objc private func refreshMenu() {
        refresh()
        refreshTasks()
    }

    @objc private func toggleTaskPanel() {
        taskPanelVisible.toggle()
        if taskPanelVisible {
            taskPanel.showPanel()
        } else {
            taskPanel.hidePanel()
        }
        rebuildMenu(for: latestSnapshot)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
