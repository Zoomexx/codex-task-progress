import Cocoa
import Foundation
import Darwin
import QuartzCore

// Shared by both monitor bundles so starting the legacy copy cannot create a
// second status item or task-progress window.
private final class MonitorInstanceLock {
    private var descriptor: Int32 = -1

    init() {
        descriptor = open("/tmp/codex-usage-monitor.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    }

    func acquire() -> Bool {
        descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
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

/// Cumulative token totals reported by one local session log. Codex keeps
/// these counters at session scope, so they must not be shown directly for a
/// newly started task.
private struct TokenTotals: Equatable {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    let total: Int

    static let zero = TokenTotals(input: 0, cachedInput: 0, output: 0, reasoning: 0, total: 0)

    var hasValue: Bool {
        max(input, cachedInput, output, reasoning, total) > 0
    }

    /// Convert a session-cumulative snapshot into the amount added after a
    /// task boundary. A counter reset is treated as unavailable rather than
    /// exposing the reset snapshot as a misleading large task total.
    func delta(from baseline: TokenTotals) -> TaskTokenUsage? {
        guard total >= baseline.total else { return nil }
        let usage = TaskTokenUsage(
            input: max(0, input - baseline.input),
            cachedInput: max(0, cachedInput - baseline.cachedInput),
            output: max(0, output - baseline.output),
            reasoning: max(0, reasoning - baseline.reasoning),
            total: max(0, total - baseline.total)
        )
        return usage.hasValue ? usage : nil
    }
}

/// Token usage for the current task/turn, derived from the cumulative local
/// session counter. It remains an estimate and is not an official bill.
private struct TaskTokenUsage {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    let total: Int

    var hasValue: Bool {
        max(input, cachedInput, output, reasoning, total) > 0
    }
}

/// One isolated token ledger per session-log file. Parallel tasks are read
/// independently, so a baseline from one conversation can never leak into
/// another conversation's row.
private struct TaskTokenLedger {
    private(set) var latestTotals: TokenTotals?
    private(set) var baseline: TokenTotals?
    private(set) var usage: TaskTokenUsage?
    private(set) var latestEventDate: Date?

    init(
        latestTotals: TokenTotals? = nil,
        baseline: TokenTotals? = nil,
        usage: TaskTokenUsage? = nil,
        latestEventDate: Date? = nil
    ) {
        self.latestTotals = latestTotals
        self.baseline = baseline
        self.usage = usage
        self.latestEventDate = latestEventDate
    }

    mutating func startTask(at date: Date, ignoringEventsAtOrBefore cutoff: Date? = nil) {
        if let cutoff, date <= cutoff { return }
        baseline = latestTotals ?? .zero
        usage = nil
    }

    mutating func record(_ totals: TokenTotals, at date: Date) {
        // Tail reads overlap old records. Keep only newer snapshots so a
        // refresh cannot make a task's displayed total move backwards.
        if let latestEventDate, date <= latestEventDate { return }
        latestTotals = totals
        latestEventDate = date
        guard let baseline else { return }
        if totals.total < baseline.total {
            // A session/log rollover reset the cumulative counter. Rebase and
            // wait for the next increment instead of showing a huge total.
            self.baseline = totals
            usage = nil
        } else {
            usage = totals.delta(from: baseline)
        }
    }
}

private func formatApproxTokenCount(_ value: Int) -> String {
    guard value > 0 else { return "0" }
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fk", Double(value) / 1_000)
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
    let needsApproval: Bool
    let approvalDetail: String?
    let approvalSince: Date?
    let tokenUsage: TaskTokenUsage?
    let tokenTotals: TokenTotals?
    let tokenBaseline: TokenTotals?
    let tokenEventDate: Date?

    var elapsed: TimeInterval {
        let start = startedAt ?? lastActivity
        let end = finishedAt ?? Date()
        return max(0, end.timeIntervalSince(start))
    }
}

private struct PendingToolCall {
    let requestedAt: Date
    let detail: String
    let isExplicit: Bool
    let toolName: String
}

private struct CachedTask {
    let modifiedAt: Date
    let fileSize: Int64
    let task: TaskProgress
}

private final class TaskReader {
    private struct SessionMetadata {
        let sessionID: String
        let cwd: String
        let source: String
        let threadSource: String
        let parentThreadID: String?
        let timestamp: Date?
    }

    private let sessionsDirectory: URL
    private let sessionIndexURL: URL
    private let fileManager = FileManager.default
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let standardDateFormatter: ISO8601DateFormatter
    private var cache: [String: CachedTask] = [:]
    private var ignoredFiles: [String: (modifiedAt: Date, fileSize: Int64)] = [:]
    private var threadNames: [String: String] = [:]
    private var sessionIndexModifiedAt: Date?
    private let approvalGraceInterval: TimeInterval = 8
    private(set) var latestCumulativeTokenTotal = 0

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
        latestCumulativeTokenTotal = 0
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
            // A session-log file is the isolation boundary for token data.
            // Key by its canonical path so two simultaneously running logs
            // cannot be merged just because their metadata uses the same
            // thread/session identifier.
            let taskKey = task.sourceFile
            if let existing = tasksByID[taskKey] {
                if task.lastActivity > existing.lastActivity {
                    tasksByID[taskKey] = task
                }
            } else {
                tasksByID[taskKey] = task
            }
        }

        cache = cache.filter { seenPaths.contains($0.key) }
        ignoredFiles = ignoredFiles.filter { seenPaths.contains($0.key) }
        let allTasks = Array(tasksByID.values)
        latestCumulativeTokenTotal = cumulativeTokenTotal(from: allTasks)
        var tasks = allTasks
        tasks.sort {
            statusPriority($0.status) != statusPriority($1.status)
                ? statusPriority($0.status) < statusPriority($1.status)
                : $0.lastActivity > $1.lastActivity
        }
        return Array(tasks.prefix(limit))
    }

    private func cumulativeTokenTotal(from tasks: [TaskProgress]) -> Int {
        var latestByLog: [String: Int] = [:]
        for task in tasks {
            guard let total = task.tokenTotals?.total, total > 0 else { continue }
            let key = task.sourceFile.isEmpty ? task.id : task.sourceFile
            latestByLog[key] = max(latestByLog[key] ?? 0, total)
        }
        return latestByLog.values.reduce(0, +)
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
        // A cold start must not read the entire multi-hundred-megabyte session
        // archive before the widget can show anything. Read a small metadata
        // prefix and the newest tail for large logs; the same tail parser is
        // then used for incremental refreshes. Small logs retain the exact
        // full-parse path below.
        if fileSize >= 1_048_576 {
            guard let task = taskFromRecentTail(url: url, modifiedAt: modifiedAt, fileSize: fileSize) else {
                return nil
            }
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
        var firstEventDate: Date?
        var latestEvent = "读取日志"
        var latestDetail: String?
        var latestStart: Date?
        var latestComplete: Date?
        var latestTerminal: Date?
        var latestTerminalStatus: TaskStatus?
        var latestModel: String?
        var tokenLedger = TaskTokenLedger()
        var planCounts: (completed: Int, total: Int, current: String?)?
        var pendingToolCalls: [String: PendingToolCall] = [:]
        var latestApprovalEvent: PendingToolCall?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let date = (object["timestamp"] as? String).flatMap(parseDate) ?? modifiedAt
            if firstEventDate == nil { firstEventDate = date }
            if date > latestActivity { latestActivity = date }
            updatePendingApprovals(
                from: object,
                date: date,
                pendingToolCalls: &pendingToolCalls,
                latestApprovalEvent: &latestApprovalEvent
            )

            let objectType = object["type"] as? String ?? ""
            if objectType == "session_meta", let payload = object["payload"] as? [String: Any] {
                // The session index names the conversation by session_id;
                // older records may only expose id, so retain it as fallback.
                sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? sessionID
                cwd = (payload["cwd"] as? String) ?? cwd
                source = (payload["source"] as? String) ?? source
                threadSource = (payload["thread_source"] as? String) ?? threadSource
                parentThreadID = payload["parent_thread_id"] as? String
                continue
            }

            if objectType == "event_msg", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                if payloadType == "token_count", let totals = tokenTotals(from: payload) {
                    tokenLedger.record(totals, at: date)
                }
                switch payloadType {
                case "task_started":
                    latestStart = date
                    // total_token_usage is session-cumulative. Establish the
                    // baseline immediately before this task starts, then
                    // expose only the subsequent increments.
                    tokenLedger.startTask(at: date)
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
                case "token_count":
                    // Token events update the numeric summary without
                    // replacing the task's useful progress detail.
                    break
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

        let isActive = status == .running || status == .waiting
        let effectiveStart: Date
        if status == .waiting {
            effectiveStart = latestUserDate ?? latestStart ?? firstUserDate ?? firstEventDate ?? latestActivity
        } else {
            effectiveStart = latestStart ?? firstUserDate ?? firstEventDate ?? latestActivity
        }
        let effectiveFinish = isActive ? nil : terminalDate
        let approval = isActive ? approvalState(
            pendingToolCalls: pendingToolCalls,
            latestApprovalEvent: latestApprovalEvent,
            now: Date()
        ) : nil
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
            startedAt: effectiveStart,
            finishedAt: effectiveFinish,
            lastEvent: latestEvent,
            detail: planCounts?.current ?? latestDetail ?? latestEvent,
            model: latestModel,
            sourceFile: url.path,
            isSubagent: parentThreadID != nil,
            completedSteps: planCounts?.completed,
            totalSteps: planCounts?.total,
            currentStep: planCounts?.current,
            needsApproval: approval != nil,
            approvalDetail: approval?.detail,
            approvalSince: approval?.requestedAt,
            tokenUsage: tokenLedger.usage?.hasValue == true ? tokenLedger.usage : nil,
            tokenTotals: tokenLedger.latestTotals,
            tokenBaseline: tokenLedger.baseline,
            tokenEventDate: tokenLedger.latestEventDate
        )
        cache[url.path] = CachedTask(modifiedAt: modifiedAt, fileSize: fileSize, task: task)
        return task
    }

    private func taskFromRecentTail(url: URL, modifiedAt: Date, fileSize: Int64) -> TaskProgress? {
        let fallbackID = url.deletingPathExtension().lastPathComponent
        let metadata = sessionMetadata(from: url, fallbackID: fallbackID)
        if metadata.threadSource == "guardian_review" || metadata.source == "guardian_review" {
            ignoredFiles[url.path] = (modifiedAt: modifiedAt, fileSize: fileSize)
            return nil
        }
        let tail = readTailData(from: url, maxBytes: 1_048_576)
        let tailTitle = tail.flatMap(recentUserTitle(from:))
        let title = cleanTitle(threadNames[metadata.sessionID] ?? tailTitle ?? "未命名任务")
        let project = metadata.cwd.isEmpty ? "当前工作区" : URL(fileURLWithPath: metadata.cwd).lastPathComponent
        let seed = TaskProgress(
            id: metadata.sessionID,
            title: title.isEmpty ? "未命名任务" : title,
            project: project.isEmpty ? "当前工作区" : project,
            cwd: metadata.cwd,
            status: .idle,
            lastActivity: metadata.timestamp ?? modifiedAt,
            startedAt: metadata.timestamp,
            finishedAt: nil,
            lastEvent: "读取日志",
            detail: "读取日志",
            model: nil,
            sourceFile: url.path,
            isSubagent: metadata.parentThreadID != nil,
            completedSteps: nil,
            totalSteps: nil,
            currentStep: nil,
            needsApproval: false,
            approvalDetail: nil,
            approvalSince: nil,
            tokenUsage: nil,
            tokenTotals: nil,
            tokenBaseline: nil,
            tokenEventDate: nil
        )
        guard let data = tail else {
            return seed
        }
        return taskFromTail(url: url, modifiedAt: modifiedAt, cached: seed, data: data)
    }

    private func recentUserTitle(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var candidate: String?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let objectType = object["type"] as? String ?? ""
            var message: String?
            if objectType == "response_item", let payload = object["payload"] as? [String: Any],
               payload["role"] as? String == "user" {
                message = userText(from: payload)
            } else if objectType == "event_msg", let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "item_completed",
                      let item = payload["item"] as? [String: Any],
                      item["type"] as? String == "UserMessage" {
                message = userText(from: item)
            }
            guard let message, !message.isEmpty else { continue }
            let cleaned = cleanTitle(message)
            if !cleaned.isEmpty && !isGenericTitle(cleaned) && !isSystemGeneratedTitle(cleaned) {
                candidate = cleaned
            }
        }
        return candidate
    }

    private func taskFromTail(
        url: URL,
        modifiedAt: Date,
        cached: TaskProgress,
        data: Data? = nil
    ) -> TaskProgress {
        guard let data = data ?? readTailData(from: url, maxBytes: 1_048_576),
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
        var tokenLedger = TaskTokenLedger(
            latestTotals: cached.tokenTotals,
            baseline: cached.tokenBaseline,
            usage: cached.tokenUsage,
            latestEventDate: cached.tokenEventDate
        )
        var planCounts: (completed: Int, total: Int, current: String?)?
        var pendingToolCalls: [String: PendingToolCall] = [:]
        var latestApprovalEvent: PendingToolCall?
        if cached.needsApproval {
            latestApprovalEvent = PendingToolCall(
                requestedAt: cached.approvalSince ?? cached.lastActivity,
                detail: cached.approvalDetail ?? "需要授权/批准",
                isExplicit: true,
                toolName: ""
            )
        }
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
            updatePendingApprovals(
                from: object,
                date: date,
                pendingToolCalls: &pendingToolCalls,
                latestApprovalEvent: &latestApprovalEvent
            )

            if objectType == "event_msg", let payload = object["payload"] as? [String: Any] {
                let payloadType = payload["type"] as? String ?? ""
                if payloadType == "token_count", let totals = tokenTotals(from: payload) {
                    tokenLedger.record(totals, at: date)
                }
                switch payloadType {
                case "task_started":
                    latestStart = date
                    // Do not let an overlapping old task_started event reset
                    // the current task's token baseline. A newer start marks
                    // a new turn; the cached token event is the cutoff.
                    tokenLedger.startTask(
                        at: date,
                        ignoringEventsAtOrBefore: cached.tokenEventDate
                    )
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
                case "token_count":
                    // Keep the task's current progress text while refreshing
                    // the cumulative token counter.
                    break
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

        let isActive = status == .running || status == .waiting
        let effectiveStart: Date
        if status == .waiting {
            effectiveStart = latestUserDate ?? latestStart ?? latestActivity
        } else {
            effectiveStart = latestStart ?? latestActivity
        }
        let effectiveFinish = isActive ? nil : latestTerminal
        let approval = isActive ? approvalState(
            pendingToolCalls: pendingToolCalls,
            latestApprovalEvent: latestApprovalEvent,
            now: Date()
        ) : nil
        return TaskProgress(
            id: cached.id,
            title: threadNames[cached.id] ?? cached.title,
            project: cached.project,
            cwd: cached.cwd,
            status: status,
            lastActivity: latestActivity,
            startedAt: effectiveStart,
            finishedAt: effectiveFinish,
            lastEvent: latestEvent,
            detail: planCounts?.current ?? latestDetail,
            model: latestModel,
            sourceFile: cached.sourceFile,
            isSubagent: cached.isSubagent,
            completedSteps: planCounts?.completed ?? cached.completedSteps,
            totalSteps: planCounts?.total ?? cached.totalSteps,
            currentStep: planCounts?.current ?? cached.currentStep,
            needsApproval: approval != nil,
            approvalDetail: approval?.detail,
            approvalSince: approval?.requestedAt,
            tokenUsage: tokenLedger.usage?.hasValue == true ? tokenLedger.usage : nil,
            tokenTotals: tokenLedger.latestTotals,
            tokenBaseline: tokenLedger.baseline,
            tokenEventDate: tokenLedger.latestEventDate
        )
    }

    private func updatePendingApprovals(
        from object: [String: Any],
        date: Date,
        pendingToolCalls: inout [String: PendingToolCall],
        latestApprovalEvent: inout PendingToolCall?
    ) {
        let objectType = (object["type"] as? String)?.lowercased() ?? ""
        if objectType == "event_msg", let payload = object["payload"] as? [String: Any] {
            let payloadType = (payload["type"] as? String)?.lowercased() ?? ""
            if isApprovalEventType(payloadType) {
                latestApprovalEvent = PendingToolCall(
                    requestedAt: date,
                    detail: "等待你的授权/批准",
                    isExplicit: true,
                    toolName: payloadType
                )
            } else if payloadType == "task_complete" || payloadType == "turn_aborted" {
                pendingToolCalls.removeAll()
                latestApprovalEvent = nil
            }
            return
        }

        guard objectType == "response_item",
              let payload = object["payload"] as? [String: Any] else {
            return
        }
        let payloadType = (payload["type"] as? String)?.lowercased() ?? ""
        if isToolOutputType(payloadType) {
            if let callID = callIdentifier(from: payload) {
                pendingToolCalls.removeValue(forKey: callID)
            }
            // An output means the tool call was resolved. If an approval event
            // was emitted separately, it is resolved by the same output.
            latestApprovalEvent = nil
            return
        }

        guard isToolCallType(payloadType),
              let callID = callIdentifier(from: payload) else {
            return
        }
        guard let candidate = approvalCandidate(from: payload, date: date) else {
            let status = normalizedString(payload["status"])
            if isTerminalCallStatus(status) {
                pendingToolCalls.removeValue(forKey: callID)
            }
            return
        }
        // Codex can mark the request item as `completed` when the tool-call
        // envelope has been emitted, before the actual tool result arrives.
        // Keep approval candidates alive until the matching output event so
        // the approval banner remains visible while the card is pending.
        pendingToolCalls[callID] = candidate
    }

    private func approvalState(
        pendingToolCalls: [String: PendingToolCall],
        latestApprovalEvent: PendingToolCall?,
        now: Date
    ) -> PendingToolCall? {
        if let latestApprovalEvent {
            return latestApprovalEvent
        }
        return pendingToolCalls.values
            .filter { $0.isExplicit || now.timeIntervalSince($0.requestedAt) >= approvalGraceInterval }
            .min { $0.requestedAt < $1.requestedAt }
    }

    private func approvalCandidate(from payload: [String: Any], date: Date) -> PendingToolCall? {
        let toolName = (payload["name"] as? String) ?? (payload["type"] as? String) ?? "工具"
        let explicit = hasExplicitApprovalSignal(in: payload)
        // Shell calls can be long-running without needing approval. For browser
        // and computer-use calls there is no reliable status field while the
        // app's approval card is open, so allow the grace-period fallback only
        // for those interactive surfaces.
        let graceEligible = isInteractiveApprovalTool(toolName)
        guard explicit || graceEligible else { return nil }
        return PendingToolCall(
            requestedAt: date,
            detail: approvalDetail(for: toolName),
            isExplicit: explicit,
            toolName: toolName
        )
    }

    private func callIdentifier(from payload: [String: Any]) -> String? {
        for key in ["call_id", "callId", "id"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func isToolCallType(_ type: String) -> Bool {
        ["custom_tool_call", "function_call", "mcp_tool_call", "computer_use_call"].contains(type)
    }

    private func isToolOutputType(_ type: String) -> Bool {
        ["custom_tool_call_output", "function_call_output", "custom_tool_result", "mcp_tool_call_output"].contains(type)
    }

    private func isTerminalCallStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return [
            "completed", "complete", "done", "succeeded", "success",
            "failed", "error", "cancelled", "canceled", "rejected",
            "declined", "denied"
        ].contains(status)
    }

    private func isApprovalPendingStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return status.contains("approval") || status.contains("authoriz") || status.contains("permission")
            || ["requires_action", "awaiting_user", "waiting_for_user", "pending"].contains(status)
    }

    private func isApprovalEventType(_ type: String) -> Bool {
        type.contains("approval") || type.contains("authoriz") || type.contains("permission")
            || type == "elicitation" || type == "user_confirmation"
    }

    private func hasExplicitApprovalSignal(in payload: [String: Any]) -> Bool {
        if isApprovalPendingStatus(normalizedString(payload["status"])) {
            return true
        }
        let keyNames = payload.keys.map { $0.lowercased() }
        if keyNames.contains(where: {
            $0.contains("approval") || $0.contains("authoriz") || $0.contains("permission")
        }) {
            return true
        }
        let serialized = serializedPayload(payload).lowercased()
        return [
            "require_escalated", "sandbox_permissions", "approval_request",
            "approvalrequest", "requires_approval", "requiresapproval",
            "awaiting_approval", "awaitingapproval", "createelicitation"
        ].contains { serialized.contains($0) }
    }

    private func isInteractiveApprovalTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("browser")
            || normalized.contains("chrome")
            || normalized.contains("computer")
            || normalized.contains("node_repl")
    }

    private func approvalDetail(for toolName: String) -> String {
        let normalized = toolName.lowercased()
        if normalized.contains("browser") || normalized.contains("chrome") || normalized.contains("web") {
            return "等待批准浏览器操作"
        }
        if normalized.contains("computer") || normalized.contains("node_repl") {
            return "等待批准软件操作"
        }
        if normalized == "exec" || normalized.contains("exec") || normalized.contains("apply_patch") {
            return "等待授权执行本机操作"
        }
        return "等待你的授权/批准"
    }

    private func serializedPayload(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
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

    private func sessionMetadata(from url: URL, fallbackID: String) -> SessionMetadata {
        var sessionID = fallbackID
        var cwd = ""
        var source = ""
        var threadSource = ""
        var parentThreadID: String?
        var timestamp: Date?

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let prefixData: Data?
            do {
                prefixData = try handle.read(upToCount: 65_536)
            } catch {
                prefixData = nil
            }
            if let prefixData,
               let text = String(data: prefixData, encoding: .utf8) {
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let lineData = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }
                    guard object["type"] as? String == "session_meta",
                          let payload = object["payload"] as? [String: Any] else {
                        continue
                    }
                    sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? sessionID
                    cwd = payload["cwd"] as? String ?? cwd
                    source = payload["source"] as? String ?? source
                    threadSource = payload["thread_source"] as? String ?? threadSource
                    parentThreadID = payload["parent_thread_id"] as? String
                    timestamp = (object["timestamp"] as? String).flatMap(parseDate)
                    break
                }
            }
        }
        return SessionMetadata(
            sessionID: sessionID,
            cwd: cwd,
            source: source,
            threadSource: threadSource,
            parentThreadID: parentThreadID,
            timestamp: timestamp
        )
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
        case "approval_request", "exec_approval_request", "authorization_request", "permission_request", "elicitation": return "需要授权/批准"
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

    private func isSystemGeneratedTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("codex agent history")
            || normalized.contains("permissions instructions")
            || normalized.contains("environment_context")
            || normalized.hasPrefix("# agents")
            || normalized.hasPrefix("you are judging")
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

    private func tokenTotals(from payload: [String: Any]) -> TokenTotals? {
        guard let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any] else {
            return nil
        }
        let input = integer(totalUsage["input_tokens"])
        let cachedInput = integer(totalUsage["cached_input_tokens"])
        let output = integer(totalUsage["output_tokens"])
        let reasoning = integer(totalUsage["reasoning_output_tokens"])
        let reportedTotal = integer(totalUsage["total_tokens"])
        // Some older session records omit total_tokens. Keep the displayed
        // estimate useful without counting cached input twice.
        let total = reportedTotal > 0 ? reportedTotal : input + output + reasoning
        let totals = TokenTotals(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total
        )
        return totals.hasValue ? totals : nil
    }

    private func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return max(0, number.intValue)
        }
        if let string = value as? String, let number = Int(string) {
            return max(0, number)
        }
        return 0
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
    }
}

/// A deliberately quiet activity cue for the otherwise unused lower part of
/// the task card. It uses one moving layer, never changes the panel geometry,
/// and becomes a still indicator when the user has enabled Reduce Motion.
private final class TaskActivityView: NSView {
    private let movingLayer = CALayer()
    private var shouldAnimate = false
    private var accentColor = TaskStatus.running.color
    private let movingWidth: CGFloat = 34
    private var configuredSize = CGSize.zero
    private var configuredActive = false
    private var configuredColor: NSColor?
    private var configuredReduceMotion: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        movingLayer.cornerRadius = 1.5
        movingLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "backgroundColor": NSNull()
        ]
        layer?.addSublayer(movingLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(active: Bool, color: NSColor) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let stateChanged = active != configuredActive
            || configuredColor?.isEqual(color) != true
            || configuredReduceMotion != reduceMotion
            || configuredSize != bounds.size
        shouldAnimate = active
        accentColor = color
        isHidden = !active
        needsDisplay = true
        if stateChanged {
            configureLayer(reduceMotion: reduceMotion)
        }
    }

    override func layout() {
        super.layout()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if configuredSize != bounds.size || configuredActive != shouldAnimate || configuredReduceMotion != reduceMotion {
            configureLayer(reduceMotion: reduceMotion)
        } else if shouldAnimate {
            // A parent resize can move this view without changing its size.
            // Keep the presentation layer in the new local coordinate space
            // without removing the long-lived travel animation.
            movingLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard shouldAnimate, bounds.width > movingWidth else { return }
        let trackRect = NSRect(
            x: 0,
            y: max(0, (bounds.height - 2) / 2),
            width: bounds.width,
            height: 2
        )
        accentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1).fill()
    }

    private func configureLayer(reduceMotion: Bool) {
        movingLayer.removeAllAnimations()
        configuredSize = bounds.size
        configuredActive = shouldAnimate
        configuredColor = accentColor
        configuredReduceMotion = reduceMotion
        guard shouldAnimate, bounds.width > movingWidth else {
            movingLayer.opacity = 0
            return
        }

        movingLayer.backgroundColor = accentColor.withAlphaComponent(0.72).cgColor
        movingLayer.bounds = NSRect(x: 0, y: 0, width: movingWidth, height: 3)
        movingLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        if reduceMotion {
            movingLayer.opacity = 0.58
            return
        }

        movingLayer.opacity = 1
        let travel = max(0, (bounds.width - movingWidth) / 2)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -travel
        animation.toValue = travel
        animation.duration = 1.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        movingLayer.add(animation, forKey: "task-activity-travel")
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
            updateActivityView()
            needsDisplay = true
        }
    }
    var onSelect: ((TaskProgress) -> Void)?
    var onShowMore: ((String, [TaskProgress]) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hitRows: [HitRow] = []

    // The board intentionally keeps one representative row per section. The
    // remaining rows open in the detail popover, so the card can stay airy
    // without repeating summary counts or making the status text unreadable.
    private let rowHeight: CGFloat = 46
    private let sectionHeaderHeight: CGFloat = 21
    private let sectionBottomSpacing: CGFloat = 7
    private let approvalBannerHeight: CGFloat = 36
    private let headerHeight: CGFloat = 46
    private let activityView: TaskActivityView

    override init(frame frameRect: NSRect) {
        activityView = TaskActivityView(frame: .zero)
        super.init(frame: frameRect)
        addSubview(activityView)
        updateActivityView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateActivityView()
    }

    var preferredHeight: CGFloat {
        let active = tasks.filter { $0.status == .running || $0.status == .waiting }
        let finished = tasks.filter { $0.status != .running && $0.status != .waiting }
        var contentHeight: CGFloat = headerHeight
        if tasks.contains(where: \.needsApproval) {
            contentHeight += approvalBannerHeight + 6
        }
        for count in [active.count, finished.count] {
            let visibleRows = count == 0 ? 1 : 1
            contentHeight += sectionHeaderHeight + CGFloat(visibleRows) * rowHeight + 1
        }
        // Keep a stable compact frame. Shrinking below this height makes
        // macOS re-anchor the floating window at its bottom edge, which
        // visually pushes the content down and clips the last detail line.
        return max(220, contentHeight + 1)
    }

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
        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: cardRect, xRadius: 14, yRadius: 14)
        // Keep the user's translucent desktop behavior while keeping the card
        // visually quiet. The controller supplies the native backdrop behind
        // this view so wallpaper text does not become a second set of labels.
        let topColor = NSColor.controlBackgroundColor.withAlphaComponent(0.98)
        let bottomColor = NSColor.windowBackgroundColor.withAlphaComponent(0.90)
        if let gradient = NSGradient(colors: [topColor, bottomColor]) {
            gradient.draw(in: background, angle: -90)
        } else {
            bottomColor.setFill()
            background.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.42).setStroke()
        background.lineWidth = 1
        background.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        drawText("任务进度", in: NSRect(x: 15, y: 16, width: bounds.width - 30, height: 22), attributes: titleAttributes)

        let active = sortedTasks(statuses: [.running, .waiting])
        let finished = sortedTasks(statuses: [.completed, .interrupted, .idle])
        hitRows = []
        var y: CGFloat = headerHeight
        let approvalCount = tasks.filter(\.needsApproval).count
        if approvalCount > 0 {
            y += 6
            drawApprovalBanner(count: approvalCount, y: &y)
        }
        drawSection("进行中", tasks: active, y: &y)
        drawSection("已完成", tasks: finished, y: &y)

        // Stroke the frame last so the bottom edge stays continuous even when
        // the final detail line reaches the lower safe area.
        NSColor.separatorColor.withAlphaComponent(0.42).setStroke()
        background.lineWidth = 1
        background.stroke()
    }

    private func updateActivityView() {
        let activeTasks = sortedTasks(statuses: [.running, .waiting])
        // The section renderer adds a small trailing gap after the last row.
        // Start the centering calculation at the row's actual lower edge so
        // the indicator sits in the visual middle of the remaining whitespace
        // instead of drifting toward the card's bottom border.
        let contentBottom = max(0, estimatedContentBottom() - sectionBottomSpacing)
        let available = bounds.height - contentBottom
        let activityHeight: CGFloat = 16
        let hasSpace = available >= activityHeight + 8
        let active = !activeTasks.isEmpty && hasSpace
        let y = contentBottom + max(0, (available - activityHeight) / 2)
        activityView.frame = NSRect(
            x: 34,
            y: y,
            width: max(0, bounds.width - 68),
            height: activityHeight
        )
        activityView.update(active: active, color: activeTasks.first?.status.color ?? TaskStatus.running.color)
    }

    private func estimatedContentBottom() -> CGFloat {
        var height = headerHeight
        if tasks.contains(where: \.needsApproval) {
            height += 6 + approvalBannerHeight
        }
        // drawSection always renders one row (or one empty row), followed by
        // the same compact bottom spacing. Keep the animation below that
        // content instead of placing it over a task detail line.
        height += 2 * (sectionHeaderHeight + rowHeight + sectionBottomSpacing)
        return height
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
        let sectionColor = title == "进行中" ? TaskStatus.running.color : TaskStatus.completed.color
        let sectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.3, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        sectionColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: 19, y: y + 7, width: 6, height: 6)).fill()
        drawText(
            title,
            in: NSRect(x: 33, y: y + 1, width: 70, height: 16),
            attributes: sectionAttributes
        )
        let hasMore = tasks.count > 1
        if hasMore {
            let remainingTasks = Array(tasks.dropFirst())
            let actionFrame = NSRect(x: bounds.width - 106, y: y, width: 88, height: sectionHeaderHeight)
            hitRows.append(HitRow(
                frame: actionFrame,
                task: nil,
                moreTitle: title,
                moreTasks: remainingTasks
            ))
            let moreAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.7, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor
            ]
            drawText("其余 \(remainingTasks.count) 项", in: NSRect(x: bounds.width - 103, y: y + 2, width: 66, height: 15), attributes: moreAttributes)
            drawChevron(at: NSPoint(x: bounds.width - 22, y: y + sectionHeaderHeight / 2), color: NSColor.controlAccentColor)
        }
        sectionColor.withAlphaComponent(0.18).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 108, y: y + 12.5))
        divider.line(to: NSPoint(x: bounds.width - (hasMore ? 116 : 18), y: y + 12.5))
        divider.lineWidth = 1
        divider.stroke()
        y += sectionHeaderHeight

        guard let firstTask = tasks.first else {
            drawEmptyRow(at: y, color: sectionColor)
            let emptyAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            drawText("暂无任务", in: NSRect(x: 34, y: y + 16, width: bounds.width - 60, height: 14), attributes: emptyAttributes)
            y += rowHeight + sectionBottomSpacing
            return
        }
        drawTaskRow(firstTask, y: &y)
        y += sectionBottomSpacing
    }

    private func drawTaskRow(_ task: TaskProgress, y: inout CGFloat) {
        let rowFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
        hitRows.append(HitRow(frame: rowFrame, task: task, moreTitle: nil, moreTasks: []))
        drawTaskBackground(at: y, status: task.status, highlighted: task.needsApproval)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.8, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        drawText(task.title, in: NSRect(x: 34, y: y + 7, width: bounds.width - 58, height: 16), attributes: titleAttributes)

        let detail = detailText(for: task)
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.1, weight: task.needsApproval ? .semibold : .regular),
            .foregroundColor: task.needsApproval ? NSColor.systemOrange : NSColor.secondaryLabelColor
        ]
        drawText(detail, in: NSRect(x: 34, y: y + 27, width: bounds.width - 58, height: 13), attributes: detailAttributes)
        y += rowHeight
    }

    private func drawApprovalBanner(count: Int, y: inout CGFloat) {
        let text = count == 1 ? "需要授权 / 批准" : "需要授权 / 批准 · \(count) 项"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.2, weight: .semibold),
            .foregroundColor: NSColor.systemOrange
        ]
        NSColor.systemOrange.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 19, y: y + 10, width: 3, height: 16),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
        drawText(text, in: NSRect(x: 34, y: y + 11, width: bounds.width - 58, height: 14), attributes: attributes)
        y += approvalBannerHeight
    }

    private func drawTaskBackground(at y: CGFloat, status: TaskStatus, highlighted: Bool) {
        status.color.withAlphaComponent(highlighted ? 0.48 : 0.28).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 19, y: y + 12, width: 3, height: rowHeight - 24),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }

    private func drawEmptyRow(at y: CGFloat, color: NSColor) {
        color.withAlphaComponent(0.28).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 19, y: y + 12, width: 3, height: rowHeight - 24),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }


    private func drawChevron(at center: NSPoint, color: NSColor) {
        color.withAlphaComponent(0.9).setStroke()
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: center.x - 3, y: center.y - 4))
        chevron.line(to: NSPoint(x: center.x + 1, y: center.y))
        chevron.line(to: NSPoint(x: center.x - 3, y: center.y + 4))
        chevron.lineWidth = 1.7
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }

    private func detailText(for task: TaskProgress) -> String {
        let isActive = task.status == .running || task.status == .waiting
        var parts: [String] = []
        if isActive {
            parts.append("已处理\(formatActiveElapsed(task.elapsed))")
        } else {
            parts.append(task.status.displayName)
            parts.append(formatElapsed(task.elapsed))
        }
        if let usage = task.tokenUsage {
            parts.append("本轮消耗约 \(formatApproxTokenCount(usage.total)) tokens")
        }
        if task.needsApproval {
            parts.append(task.approvalDetail ?? "需要授权/批准")
        } else if !task.detail.isEmpty {
            parts.append(task.detail)
        }
        if let completed = task.completedSteps, let total = task.totalSteps, total > 0 {
            parts.append("\(completed)/\(total)")
        }
        return parts.joined(separator: " · ")
    }

    private func resizeForContent() {
        let requiredHeight = preferredHeight
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

    private func formatActiveElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分\(seconds % 60)秒" }
        return "\(seconds / 3600)时\(seconds % 3600 / 60)分\(seconds % 60)秒"
    }
}

/// The main board is a fixed desktop widget. Extra tasks are intentionally
/// opened in the separate detail window instead of making the card scroll.
private final class NonScrollingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Keep the task board stationary when the pointer passes over it.
    }
}

private final class TaskDetailView: NSView {
    var sectionTitle: String = "任务详情"
    var tasks: [TaskProgress] = [] {
        didSet {
            resizeForContent()
            needsDisplay = true
        }
    }
    var onSelect: ((TaskProgress) -> Void)?
    /// The cumulative total comes from the latest snapshot in each distinct
    /// local session log. It is intentionally supplied by the controller so
    /// the detail window does not turn per-task deltas into a fake lifetime
    /// total.
    var cumulativeTokenTotal: Int?
    private var hitRows: [(frame: NSRect, task: TaskProgress)] = []
    private let rowHeight: CGFloat = 64

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)
        let topColor = NSColor.controlBackgroundColor.withAlphaComponent(0.99)
        let bottomColor = NSColor.windowBackgroundColor.withAlphaComponent(0.93)
        if let gradient = NSGradient(colors: [topColor, bottomColor]) {
            gradient.draw(in: background, angle: -90)
        } else {
            bottomColor.setFill()
            background.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.30).setStroke()
        background.lineWidth = 1
        background.stroke()
        let eyebrowAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.2, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor
        ]
        drawText("CODEX  ·  DETAILS", in: NSRect(x: 17, y: 20, width: bounds.width - 34, height: 12), attributes: eyebrowAttributes)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        drawText(sectionTitle, in: NSRect(x: 17, y: 32, width: bounds.width - 34, height: 22), attributes: headerAttributes)
        let approvalCount = tasks.filter(\.needsApproval).count
        let subtitle = approvalCount > 0
            ? "\(tasks.count) 项 · 待授权/批准 \(approvalCount)"
            : "\(tasks.count) 项 · 点击任务可打开对应会话"
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.3, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        drawText(subtitle, in: NSRect(x: 17, y: 54, width: bounds.width - 34, height: 14), attributes: subtitleAttributes)
        let cumulativeTokens = cumulativeTokenTotal ?? cumulativeTokenTotalFromVisibleLogs()
        let usageSummary = cumulativeTokens > 0
            ? "累计已消耗约 \(formatApproxTokenCount(cumulativeTokens)) tokens"
            : "累计已消耗待同步"
        let usageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.3, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor
        ]
        drawText(usageSummary, in: NSRect(x: 17, y: 68, width: bounds.width - 34, height: 14), attributes: usageAttributes)

        hitRows = []
        var y: CGFloat = 88
        for task in tasks {
            let rowFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            hitRows.append((rowFrame, task))
            drawRowBackground(at: y, highlighted: task.needsApproval, status: task.status)

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.3, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            drawText(task.title, in: NSRect(x: 32, y: y + 10, width: bounds.width - 64, height: 17), attributes: titleAttributes)

            let detail = detailText(for: task)
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.0, weight: task.needsApproval ? .semibold : .regular),
                .foregroundColor: task.needsApproval ? NSColor.systemOrange : NSColor.secondaryLabelColor
            ]
            drawText(detail, in: NSRect(x: 32, y: y + 33, width: bounds.width - 64, height: 14), attributes: detailAttributes)

            if task.needsApproval {
                let badge = NSBezierPath(roundedRect: NSRect(x: bounds.width - 54, y: y + 20, width: 34, height: 21), xRadius: 10.5, yRadius: 10.5)
                NSColor.systemOrange.withAlphaComponent(0.14).setFill()
                badge.fill()
                NSColor.systemOrange.withAlphaComponent(0.38).setStroke()
                badge.lineWidth = 1
                badge.stroke()
                let badgeAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8.2, weight: .semibold),
                    .foregroundColor: NSColor.systemOrange
                ]
                drawText("待处理", in: NSRect(x: bounds.width - 50, y: y + 23, width: 27, height: 13), attributes: badgeAttributes)
            }
            if task.needsApproval {
                NSColor.systemOrange.withAlphaComponent(0.74).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: 17, y: y + 17, width: 3, height: 19),
                    xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
            }
            y += rowHeight
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let match = hitRows.first(where: { $0.frame.contains(point) }) {
            onSelect?(match.task)
        }
    }

    private func cumulativeTokenTotalFromVisibleLogs() -> Int {
        var latestByLog: [String: Int] = [:]
        for task in tasks {
            guard let total = task.tokenTotals?.total, total > 0 else { continue }
            let key = task.sourceFile.isEmpty ? task.id : task.sourceFile
            latestByLog[key] = max(latestByLog[key] ?? 0, total)
        }
        return latestByLog.values.reduce(0, +)
    }

    private func resizeForContent() {
        let requiredHeight = max(126, 88 + CGFloat(tasks.count) * rowHeight + 12)
        if abs(frame.height - requiredHeight) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: requiredHeight))
        }
    }

    private func drawRowBackground(at y: CGFloat, highlighted: Bool, status: TaskStatus) {
        let color = highlighted ? NSColor.systemOrange : status.color
        color.withAlphaComponent(highlighted ? 0.62 : 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 17, y: y + 17, width: 3, height: 19), xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func detailText(for task: TaskProgress) -> String {
        let isActive = task.status == .running || task.status == .waiting
        var parts: [String] = []
        if isActive {
            parts.append("已处理\(formatActiveElapsed(task.elapsed))")
        } else {
            parts.append(task.status.displayName)
            parts.append(formatElapsed(task.elapsed))
        }
        if let usage = task.tokenUsage {
            parts.append("本轮消耗约 \(formatApproxTokenCount(usage.total)) tokens")
        }
        if task.needsApproval {
            parts.append(task.approvalDetail ?? "需要授权/批准")
        } else if !task.detail.isEmpty {
            parts.append(task.detail)
        }
        if let completed = task.completedSteps, let total = task.totalSteps, total > 0 {
            parts.append("\(completed)/\(total)")
        }
        return parts.joined(separator: " · ")
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

    private func formatActiveElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3600 { return "\(seconds / 60)分\(seconds % 60)秒" }
        return "\(seconds / 3600)时\(seconds % 3600 / 60)分\(seconds % 60)秒"
    }
}

private final class TaskDetailWindowController: NSWindowController, NSWindowDelegate {
    private let detailView: TaskDetailView
    private let scrollView: NSScrollView
    private let windowWidth: CGFloat = 420
    private weak var parentWindow: NSWindow?
    private var autoCloseTimer: Timer?
    private var autoCloseNotBefore = Date.distantFuture
    var onSelect: ((TaskProgress) -> Void)?

    init(sectionTitle: String, tasks: [TaskProgress], cumulativeTokenTotal: Int? = nil) {
        let size = NSSize(width: 420, height: 280)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(sectionTitle) · 更多任务"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        detailView = TaskDetailView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        detailView.sectionTitle = sectionTitle
        detailView.cumulativeTokenTotal = cumulativeTokenTotal
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

    func update(tasks: [TaskProgress], cumulativeTokenTotal: Int? = nil) {
        if let cumulativeTokenTotal {
            detailView.cumulativeTokenTotal = cumulativeTokenTotal
        }
        detailView.tasks = tasks
        let contentHeight = max(126, 88 + CGFloat(tasks.count) * 64 + 12)
        let visibleHeight = min(560, max(190, contentHeight + 22))
        // Keep the popover compact. Reading the current content width here can
        // inherit a stale full-screen width after a resize, which made this
        // window unexpectedly stretch across the desktop.
        detailView.setFrameSize(NSSize(width: windowWidth, height: contentHeight))
        window?.setContentSize(NSSize(width: windowWidth, height: visibleHeight))
    }

    func refreshElapsed() {
        detailView.needsDisplay = true
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
    private let panelWidth: CGFloat = 280
    private var detailWindows: [String: TaskDetailWindowController] = [:]
    private var latestCumulativeTokenTotal = 0

    init() {
        // Keep one polished, readable card on the desktop. The detail window
        // carries the rest of a section, so the main panel stays compact.
        // Keep the widget compact enough to sit quietly on the desktop. The
        // main card still shows one row per section and never scrolls; the
        // section-header action opens the remaining tasks in the detail window.
        let size = NSSize(width: panelWidth, height: 220)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screenFrame.maxX - size.width - 18, y: screenFrame.maxY - size.height - 18)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            // Use one border source: the task view draws the complete rounded
            // card. A titled panel also paints a native bottom frame, which
            // made the lower edge darker/thicker than the other three edges.
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
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
        // The window height changes with the visible rows. Keep the clip view
        // in lockstep with that resize; otherwise the last row is clipped at
        // the original launch height even though the window itself grows.
        taskView.autoresizingMask = [.width]
        let scrollView = NonScrollingScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = taskView

        // Keep one visual surface only. The task view already draws the
        // translucent rounded card; an additional visual-effect backdrop
        // would create a distracting double border around the panel.
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

    func update(tasks: [TaskProgress], cumulativeTokenTotal: Int = 0) {
        latestCumulativeTokenTotal = cumulativeTokenTotal
        taskView.tasks = tasks
        // Resize the fixed board to its compact preferred height. This keeps
        // all visible sections and the "查看其余" affordance on-screen while
        // avoiding a scrollable main widget.
        if let window {
            window.setContentSize(NSSize(width: panelWidth, height: taskView.preferredHeight))
            keepPanelOnVisibleScreen(window)
        }
        let active = tasks
            .filter { $0.status == .running || $0.status == .waiting }
            .sorted { $0.lastActivity > $1.lastActivity }
        let finished = tasks
            .filter { $0.status != .running && $0.status != .waiting }
            .sorted { $0.lastActivity > $1.lastActivity }
        updateDetailWindow(named: "进行中", tasks: Array(active.dropFirst()), cumulativeTokenTotal: latestCumulativeTokenTotal)
        updateDetailWindow(named: "已完成", tasks: Array(finished.dropFirst()), cumulativeTokenTotal: latestCumulativeTokenTotal)
    }

    private func keepPanelOnVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let margin: CGFloat = 18
        let visible = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        var frame = window.frame

        // Keep a manually chosen position whenever it is still visible. Only
        // correct the edge that would otherwise be clipped after a resize.
        if frame.maxY > visible.maxY {
            frame.origin.y -= frame.maxY - visible.maxY
        }
        if frame.minY < visible.minY {
            frame.origin.y += visible.minY - frame.minY
        }
        if frame.maxX > visible.maxX {
            frame.origin.x -= frame.maxX - visible.maxX
        }
        if frame.minX < visible.minX {
            frame.origin.x += visible.minX - frame.minX
        }
        if frame.origin != window.frame.origin {
            window.setFrameOrigin(frame.origin)
        }
    }

    func refreshElapsed() {
        taskView.needsDisplay = true
        for controller in detailWindows.values {
            controller.refreshElapsed()
        }
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
            controller = TaskDetailWindowController(
                sectionTitle: sectionTitle,
                tasks: tasks,
                cumulativeTokenTotal: latestCumulativeTokenTotal
            )
            controller.onSelect = { task in
                Self.openTask(task)
            }
            detailWindows[sectionTitle] = controller
        }
        controller.update(tasks: tasks, cumulativeTokenTotal: latestCumulativeTokenTotal)
        controller.show(relativeTo: window)
    }

    private func updateDetailWindow(
        named sectionTitle: String,
        tasks: [TaskProgress],
        cumulativeTokenTotal: Int
    ) {
        guard let controller = detailWindows[sectionTitle] else { return }
        if tasks.isEmpty {
            controller.hide()
        } else {
            controller.update(tasks: tasks, cumulativeTokenTotal: cumulativeTokenTotal)
        }
    }

    private static func openTask(_ task: TaskProgress) {
        // ChatGPT/Codex registers this deep link for a specific session. Use
        // the session id from the local log so clicking a row opens that exact
        // conversation instead of merely activating the app window.
        if !task.id.isEmpty {
            var components = URLComponents()
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/\(task.id)"
            if let url = components.url, NSWorkspace.shared.open(url) {
                return
            }
        }
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        if let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.sourceFile)])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageSyncService = UsageSyncService.shared
    private let taskReader = TaskReader()
    private let instanceLock = MonitorInstanceLock()
    private let taskQueue = DispatchQueue(label: "local.codex.usage-menu.task-reader")
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer!
    private var taskRefreshTimer: Timer!
    private var elapsedRefreshTimer: Timer!
    private var latestSnapshot = UsageSnapshot.empty
    private var latestTasks: [TaskProgress] = []
    private var taskPanel: TaskPanelController!
    private var taskPanelVisible = true
    private var taskRefreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        // Keep the menu-bar utility single-instance. Starting the app twice
        // otherwise creates duplicate usage readouts and competing panels.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let anotherInstanceIsRunning = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { $0.processIdentifier != currentPID }
            if anotherInstanceIsRunning {
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = NSMenu()

        taskPanel = TaskPanelController()
        taskPanel.showPanel()
        usageSyncService.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.latestSnapshot = snapshot
            self.statusItem.button?.attributedTitle = self.title(for: snapshot)
            self.statusItem.button?.toolTip = self.tooltip(for: snapshot)
            self.rebuildMenu(for: snapshot)
        }
        usageSyncService.start()
        refreshTasks()
        // Event notifications are the normal path. A ten-second read floor is
        // the bounded fallback when the App Server does not emit an update;
        // OfficialUsageClient coalesces requests so repeated clicks or wake-up
        // races still use one connection and one read at a time.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        taskRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshTasks()
        }
        elapsedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.taskPanel.refreshElapsed()
        }
    }

    private func refresh() {
        usageSyncService.requestRefresh()
    }

    private func refreshTasks() {
        guard !taskRefreshInFlight else { return }
        taskRefreshInFlight = true
        taskQueue.async { [weak self] in
            guard let self else { return }
            let tasks = self.taskReader.read()
            DispatchQueue.main.async {
                let taskCountChanged = self.latestTasks.count != tasks.count
                let previousApprovals = Set(self.latestTasks.filter(\.needsApproval).map(\.id))
                let currentApprovals = Set(tasks.filter(\.needsApproval).map(\.id))
                let approvalStateChanged = previousApprovals != currentApprovals
                let approvalAppeared = !currentApprovals.isEmpty && currentApprovals != previousApprovals
                self.latestTasks = tasks
                self.taskPanel.update(
                    tasks: tasks,
                    cumulativeTokenTotal: self.taskReader.latestCumulativeTokenTotal
                )
                self.taskRefreshInFlight = false
                self.statusItem.button?.attributedTitle = self.title(for: self.latestSnapshot)
                self.statusItem.button?.toolTip = self.tooltip(for: self.latestSnapshot)
                if taskCountChanged || approvalStateChanged {
                    self.rebuildMenu(for: self.latestSnapshot)
                }
                if approvalAppeared {
                    self.taskPanel.showPanel()
                }
            }
        }
    }

    private func title(for snapshot: UsageSnapshot) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        let approvalCount = latestTasks.filter(\.needsApproval).count
        let prefix = approvalCount > 0 ? "⚠ " : ""
        let result = NSMutableAttributedString(string: "\(prefix)Codex ", attributes: baseAttributes)
        appendRemainingSegment(
            to: result,
            label: "5h",
            window: displayWindow(snapshot.fiveHour, status: snapshot.status),
            baseAttributes: baseAttributes
        )
        result.append(NSAttributedString(string: " · ", attributes: baseAttributes))
        appendRemainingSegment(
            to: result,
            label: "7d",
            window: displayWindow(snapshot.sevenDay, status: snapshot.status),
            baseAttributes: baseAttributes
        )
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
        let five = remainingPercent(for: displayWindow(snapshot.fiveHour, status: snapshot.status)).map { "\(formatPercent($0))%" } ?? "暂无数据"
        let seven = remainingPercent(for: displayWindow(snapshot.sevenDay, status: snapshot.status)).map { "\(formatPercent($0))%" } ?? "暂无数据"
        let active = latestTasks.filter { $0.status == .running || $0.status == .waiting }.count
        let approvals = latestTasks.filter(\.needsApproval).count
        let approvalText = approvals > 0 ? "；\(approvals) 个任务需要授权/批准" : ""
        return "Codex 剩余用量：5 小时 \(five)，7 天 \(seven)；\(snapshot.status.displayName)；\(active) 个活跃任务\(approvalText)"
    }

    private func rebuildMenu(for snapshot: UsageSnapshot) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Codex 用量（官方 App Server）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let taskToggle = NSMenuItem(title: taskPanelVisible ? "隐藏任务窗口" : "显示任务窗口", action: #selector(toggleTaskPanel), keyEquivalent: "t")
        taskToggle.target = self
        menu.addItem(taskToggle)
        menu.addItem(infoItem("任务列表", value: "\(latestTasks.count) 个（每 4 秒刷新）"))
        let approvalCount = latestTasks.filter(\.needsApproval).count
        if approvalCount > 0 {
            let approvalItem = NSMenuItem(
                title: "⚠ 需要授权/批准：\(approvalCount) 个",
                action: nil,
                keyEquivalent: ""
            )
            approvalItem.isEnabled = false
            approvalItem.attributedTitle = NSAttributedString(string: approvalItem.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemOrange
            ])
            menu.addItem(approvalItem)
        }
        menu.addItem(.separator())

        menu.addItem(infoItem("5 小时窗口", value: windowDescription(displayWindow(snapshot.fiveHour, status: snapshot.status))))
        menu.addItem(infoItem("7 天窗口", value: windowDescription(displayWindow(snapshot.sevenDay, status: snapshot.status))))
        menu.addItem(infoItem("同步状态", value: snapshot.statusDetail ?? snapshot.status.displayName))
        menu.addItem(infoItem("最后同步", value: snapshot.receivedAt.map(formatDate) ?? "暂无数据"))
        menu.addItem(.separator())
        if snapshot.tokenDataAvailable {
            menu.addItem(infoItem("当前会话输入", value: formatTokens(snapshot.inputTokens)))
            menu.addItem(infoItem("其中缓存输入", value: formatTokens(snapshot.cachedInputTokens)))
            menu.addItem(infoItem("当前会话输出", value: formatTokens(snapshot.outputTokens)))
            menu.addItem(infoItem("推理 tokens", value: formatTokens(snapshot.reasoningTokens)))
            menu.addItem(infoItem("当前会话合计", value: formatTokens(snapshot.totalTokens)))
            if let context = snapshot.modelContextWindow {
                menu.addItem(infoItem("上下文窗口", value: formatTokens(context)))
            }
        } else {
            menu.addItem(infoItem("会话 token", value: "官方限额接口未提供"))
        }
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
        let remaining = remainingPercent(for: window).map { "\(formatPercent($0))%" } ?? "暂无官方数据"
        let used = window.usedPercent.map { "\(formatPercent($0))%" } ?? "暂无官方数据"
        guard let reset = window.resetsAt else {
            return "剩余 \(remaining)（已用 \(used)）"
        }
        return "剩余 \(remaining)（已用 \(used)），约 " + formatDate(reset) + " 重置"
    }

    private func remainingPercent(for window: UsageWindow) -> Double? {
        guard let used = window.usedPercent else { return nil }
        return max(0, min(100, 100 - used))
    }

    private func displayWindow(_ window: UsageWindow, status: UsageSyncStatus) -> UsageWindow {
        // Keep the latest valid numbers visible during a reconnect. A blank
        // placeholder makes the status bar unusable; the tooltip and menu carry
        // the explicit syncing/delayed status so a retained value is never
        // mistaken for a fresh read.
        return window
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

    func applicationWillTerminate(_ notification: Notification) {
        usageSyncService.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
