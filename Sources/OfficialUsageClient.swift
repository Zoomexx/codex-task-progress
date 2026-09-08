import Foundation
import Darwin

struct OfficialRateLimits {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

enum OfficialUsageClientError: Error, Equatable {
    case executableNotFound
    case authenticationRequired
    case processExited
    case malformedResponse
    case serverError
}

/// Small, read-only JSON-RPC client for the Codex App Server. It deliberately
/// sends only initialize/initialized and account/rateLimits/read; no thread,
/// turn, account mutation, or credential method is ever issued.
final class OfficialUsageClient {
    var onUpdate: ((OfficialRateLimits) -> Void)?
    var onError: ((Error) -> Void)?

    private let stateQueue = DispatchQueue(label: "local.codex.usage-menu.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    // Keep pipe reads on the private state queue. A short non-blocking poll is
    // more reliable here than FileHandle.readabilityHandler or a raw
    // DispatchSourceRead: both can report a transient empty read while the
    // AppKit process is backgrounded. The poller avoids both false EOFs and
    // EAGAIN busy-loops.
    private var pipePoller: DispatchSourceTimer?
    private var errorPipeClosed = false
    private var outputBuffer = Data()
    private var nextRequestID = 1
    // Every child process gets its own generation. A previous child can still
    // deliver buffered output or a termination callback after a reconnect; its
    // callbacks must never mutate the new connection's state.
    private var connectionGeneration = 0
    private var activeGeneration = 0
    private var initialized = false
    private var initializeRequestID: Int?
    private var rateLimitRequestID: Int?
    private var pendingRead = false
    private var lastRequestAt: Date?
    private var lastResult: OfficialRateLimits?

    func start() {
        stateQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func requestRateLimits(force: Bool = false) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRead = true
            self.startOnQueue()
            self.requestRateLimitsOnQueue(force: force)
        }
    }

    func stop() {
        stateQueue.sync {
            stopOnQueue()
        }
    }

    deinit {
        stop()
    }

    private func startOnQueue() {
        guard process == nil else { return }
        guard let executableURL = codexExecutableURL() else {
            notifyError(OfficialUsageClientError.executableNotFound)
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        activeGeneration = generation

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--stdio"]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        child.terminationHandler = { [weak self] _ in
            self?.stateQueue.async { [weak self] in
                self?.handleTerminationOnQueue(generation: generation)
            }
        }

        process = child
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        initialized = false
        initializeRequestID = nextRequestID
        rateLimitRequestID = nil
        lastResult = nil
        outputBuffer.removeAll(keepingCapacity: true)

        do {
            try child.run()
        } catch {
            stopOnQueue()
            notifyError(OfficialUsageClientError.processExited)
            return
        }

        installPipePollerOnQueue(
            outputHandle: outputPipe.fileHandleForReading,
            errorHandle: errorPipe.fileHandleForReading,
            generation: generation
        )

        let initializeID = initializeRequestID ?? nextRequestID
        sendRequestOnQueue(
            id: initializeID,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-usage-menu",
                    "version": "0.3.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        )
        nextRequestID = max(nextRequestID, initializeID + 1)
        pendingRead = true

        // A process that starts but never completes the initialize handshake
        // must not leave the status item in an indeterminate state forever.
        // Reconnect once the bounded handshake deadline expires; generation
        // guards make any late bytes from the old child harmless.
        stateQueue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self,
                  generation == self.activeGeneration,
                  self.process != nil,
                  !self.initialized else { return }
            self.stopOnQueue()
            self.startOnQueue()
        }
    }

    private func installPipePollerOnQueue(
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        generation: Int
    ) {
        // Non-blocking descriptors let the timer check both pipes without ever
        // blocking the state queue while the App Server is idle.
        setNonBlocking(outputHandle.fileDescriptor)
        setNonBlocking(errorHandle.fileDescriptor)

        errorPipeClosed = false
        let poller = DispatchSource.makeTimerSource(queue: stateQueue)
        poller.schedule(
            deadline: .now(),
            repeating: .milliseconds(100),
            leeway: .milliseconds(20)
        )
        poller.setEventHandler { [weak self] in
            guard let self, generation == self.activeGeneration else { return }

            switch self.readPipeData(from: outputHandle.fileDescriptor) {
            case .data(let data):
                self.consumeOutputOnQueue(data, generation: generation)
            case .wouldBlock:
                break
            case .eof, .failed:
                poller.cancel()
                self.handleTerminationOnQueue(generation: generation)
            }

            guard !self.errorPipeClosed else { return }
            switch self.readPipeData(from: errorHandle.fileDescriptor) {
            case .data:
                // Drain stderr without retaining it. App Server diagnostics can
                // contain implementation details, so they are never cached or shown.
                break
            case .wouldBlock:
                break
            case .eof, .failed:
                self.errorPipeClosed = true
            }
        }
        poller.setCancelHandler { [weak self] in
            self?.errorPipeClosed = true
            try? outputHandle.close()
            try? errorHandle.close()
        }
        poller.resume()
        self.pipePoller = poller
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private enum PipeReadResult {
        case data(Data)
        case wouldBlock
        case eof
        case failed
    }

    private func readPipeData(from fileDescriptor: Int32) -> PipeReadResult {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return Darwin.read(fileDescriptor, baseAddress, rawBuffer.count)
        }
        if count > 0 {
            return .data(Data(buffer.prefix(count)))
        }
        if count == 0 {
            return .eof
        }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return .wouldBlock
        }
        return .failed
    }

    private func stopOnQueue() {
        connectionGeneration += 1
        activeGeneration = connectionGeneration
        let child = process
        pipePoller?.cancel()
        pipePoller = nil
        errorPipeClosed = true
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        initialized = false
        initializeRequestID = nil
        rateLimitRequestID = nil
        pendingRead = false
        lastRequestAt = nil

        // Process.terminate() is asynchronous and the App Server can leave
        // the pipe-backed process alive. Reconnecting before it exits creates
        // duplicate App Servers, which in turn allows stale responses to race
        // with fresh ones. This child is owned by this client, so terminate it
        // completely before any future start.
        if let child, child.isRunning {
            child.terminate()
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
            }
            child.waitUntilExit()
        }
    }

    private func handleTerminationOnQueue(generation: Int) {
        guard generation == activeGeneration, process != nil else { return }
        pipePoller?.cancel()
        pipePoller = nil
        errorPipeClosed = true
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        initialized = false
        initializeRequestID = nil
        rateLimitRequestID = nil
        notifyError(OfficialUsageClientError.processExited)
    }

    private func requestRateLimitsOnQueue(force _: Bool) {
        guard process != nil else { return }
        guard initialized else { return }
        guard pendingRead else { return }

        let now = Date()
        if let lastRequestAt,
           rateLimitRequestID != nil,
           now.timeIntervalSince(lastRequestAt) > 15 {
            // A broken pipe or a sleeping server must not leave the one client
            // permanently stuck behind an in-flight request.
            stopOnQueue()
            startOnQueue()
            return
        }
        guard rateLimitRequestID == nil else { return }
        // All callers, including an explicit menu refresh, share the same
        // ten-second floor. This prevents repeated clicks or wake-up races from
        // turning a read-only status check into high-frequency RPC traffic.
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < 10 {
            return
        }

        let requestID = nextRequestID
        nextRequestID += 1
        rateLimitRequestID = requestID
        pendingRead = false
        lastRequestAt = now
        sendRequestOnQueue(id: requestID, method: "account/rateLimits/read", params: [:])
    }

    private func consumeOutputOnQueue(_ data: Data, generation: Int) {
        guard generation == activeGeneration else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            handleMessageOnQueue(object)
        }
    }

    private func handleMessageOnQueue(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            if method == "account/rateLimits/updated",
               let params = object["params"] as? [String: Any],
               let parsed = Self.parseRateLimits(params) {
                let merged = merge(lastResult, parsed)
                lastResult = merged
                emitUpdate(merged)
            }
            return
        }

        guard let responseID = Self.integer(object["id"]) else { return }
        if let error = object["error"] as? [String: Any] {
            if responseID == rateLimitRequestID {
                rateLimitRequestID = nil
            }
            let code = Self.integer(error["code"])
            notifyError(code == -32600 ? OfficialUsageClientError.authenticationRequired : OfficialUsageClientError.serverError)
            return
        }

        if responseID == initializeRequestID {
            initialized = true
            initializeRequestID = nil
            sendNotificationOnQueue(method: "initialized", params: [:])
            requestRateLimitsOnQueue(force: true)
            return
        }

        guard responseID == rateLimitRequestID else { return }
        rateLimitRequestID = nil
        guard let result = object["result"] as? [String: Any],
              let parsed = Self.parseRateLimits(result) else {
            notifyError(OfficialUsageClientError.malformedResponse)
            return
        }
        let merged = merge(lastResult, parsed)
        lastResult = merged
        emitUpdate(merged)
    }

    private func merge(_ previous: OfficialRateLimits?, _ update: OfficialRateLimits) -> OfficialRateLimits {
        guard let previous else { return update }
        return OfficialRateLimits(
            fiveHour: UsageWindow(
                usedPercent: update.fiveHour.usedPercent ?? previous.fiveHour.usedPercent,
                resetsAt: update.fiveHour.resetsAt ?? previous.fiveHour.resetsAt
            ),
            sevenDay: UsageWindow(
                usedPercent: update.sevenDay.usedPercent ?? previous.sevenDay.usedPercent,
                resetsAt: update.sevenDay.resetsAt ?? previous.sevenDay.resetsAt
            )
        )
    }

    private func emitUpdate(_ value: OfficialRateLimits) {
        onUpdate?(value)
    }

    private func notifyError(_ error: Error) {
        onError?(error)
    }

    private func sendRequestOnQueue(id: Int, method: String, params: [String: Any]) {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        object["params"] = params
        sendObjectOnQueue(object)
    }

    private func sendNotificationOnQueue(method: String, params: [String: Any]) {
        sendObjectOnQueue(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func sendObjectOnQueue(_ object: [String: Any]) {
        guard let input,
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            notifyError(OfficialUsageClientError.processExited)
            return
        }
        var line = data
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            notifyError(OfficialUsageClientError.processExited)
        }
    }

    private func codexExecutableURL() -> URL? {
        let fixedCandidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        for path in fixedCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":")
        for entry in pathEntries {
            let path = String(entry) + "/codex"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Protocol decoding

    private struct ParsedWindow {
        let window: UsageWindow
        let durationMinutes: Double?
    }

    /// Decodes the official v2 RateLimitSnapshot shape. This is internal so the
    /// offline smoke test can exercise it without launching a process.
    static func parseRateLimits(_ object: [String: Any]) -> OfficialRateLimits? {
        let snapshot: [String: Any]
        if let rateLimits = object["rateLimits"] as? [String: Any] {
            snapshot = rateLimits
        } else if let byLimit = object["rateLimitsByLimitId"] as? [String: Any],
                  let codex = (byLimit["codex"] as? [String: Any]) ?? (byLimit["default"] as? [String: Any]) {
            snapshot = codex
        } else {
            snapshot = object
        }

        let primary = parsedWindow(snapshot["primary"])
        let secondary = parsedWindow(snapshot["secondary"])
        let candidates = [(role: "primary", value: primary), (role: "secondary", value: secondary)]

        let five = selectWindow(candidates: candidates, targetMinutes: 300, fallbackRole: "primary")
        let seven = selectWindow(candidates: candidates, targetMinutes: 10_080, fallbackRole: "secondary")
        guard five.window.usedPercent != nil || seven.window.usedPercent != nil else { return nil }
        return OfficialRateLimits(fiveHour: five.window, sevenDay: seven.window)
    }

    private static func parsedWindow(_ value: Any?) -> ParsedWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used = number(object["usedPercent"] ?? object["used_percent"])
        let reset = date(object["resetsAt"] ?? object["resets_at"])
        let duration = number(object["windowDurationMins"] ?? object["window_duration_mins"])
        return ParsedWindow(window: UsageWindow(usedPercent: used, resetsAt: reset), durationMinutes: duration)
    }

    private static func selectWindow(
        candidates: [(role: String, value: ParsedWindow?)],
        targetMinutes: Double,
        fallbackRole: String
    ) -> ParsedWindow {
        if let exact = candidates.compactMap({ candidate -> ParsedWindow? in
            guard let value = candidate.value, let duration = value.durationMinutes else { return nil }
            return abs(duration - targetMinutes) <= 5 ? value : nil
        }).first {
            return exact
        }
        if targetMinutes < 1_000,
           let short = candidates.compactMap({ candidate -> ParsedWindow? in
               guard let value = candidate.value, let duration = value.durationMinutes else { return nil }
               return duration < 1_000 ? value : nil
           }).first {
            return short
        }
        if targetMinutes >= 1_000,
           let long = candidates.compactMap({ candidate -> ParsedWindow? in
               guard let value = candidate.value, let duration = value.durationMinutes else { return nil }
               return duration >= 1_000 ? value : nil
           }).first {
            return long
        }
        return candidates.first(where: { $0.role == fallbackRole })?.value
            ?? ParsedWindow(window: UsageWindow(usedPercent: nil, resetsAt: nil), durationMinutes: nil)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String {
            if let raw = Double(string) {
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
