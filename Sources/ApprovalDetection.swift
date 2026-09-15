import Foundation

/// Approval detection shared by the log reader and its focused smoke test.
/// A Computer Use permission sheet is not emitted as a separate log event;
/// while it is open the wrapper tool call exists without its output. Detect
/// the local interactive envelope so the task can be shown as pending instead
/// of looking like an ordinary running command.
enum ApprovalDetection {
    static func isInteractiveTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("browser")
            || normalized.contains("chrome")
            || normalized.contains("computer")
            || normalized.contains("node_repl")
            || normalized.contains("node-repl")
            || normalized.contains("cua")
            || normalized.contains("playwright")
            || normalized.contains("quicktime")
    }

    static func isInteractivePayload(_ payload: [String: Any]) -> Bool {
        let serialized = serializedPayload(payload).lowercased()
        let hasNodeRepl = serialized.contains("node_repl") || serialized.contains("node-repl")
        let hasComputerUseMarker = serialized.contains("@oai/sky")
            || serialized.contains("sky.")
            || serialized.contains("cua.")
            || serialized.contains("computer_use")
            || serialized.contains("computer-use")
            || serialized.contains("get_app_state")
            || serialized.contains("getappstate")
            || serialized.contains("mcp__cua")
        let hasBrowserMarker = serialized.contains("browser")
            || serialized.contains("chrome")
            || serialized.contains("safari")
            || serialized.contains("playwright")
            || serialized.contains("quicktime")
        let hasBrowserAction = serialized.contains("browser.")
            || serialized.contains("chrome.")
            || serialized.contains("safari.")
            || serialized.contains("playwright.")
        // The current wrapper is mcp__node_repl__js, but older/newer local
        // builds may omit the namespace in the serialized input. Keep the
        // namespace optional while requiring a concrete interactive marker so
        // ordinary node-repl tool discovery is not flagged.
        return (hasNodeRepl && (hasComputerUseMarker || hasBrowserMarker))
            || hasComputerUseMarker
            || hasBrowserAction
    }

    static func detail(for toolName: String, interactivePayload: Bool) -> String {
        if interactivePayload {
            return "等待批准软件操作"
        }
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
        return "待批准"
    }

    private static func serializedPayload(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
