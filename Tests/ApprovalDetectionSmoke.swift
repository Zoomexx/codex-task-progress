import Foundation

@main
struct ApprovalDetectionSmoke {
    static func main() {
        let computerUseEnvelope: [String: Any] = [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "call-fixture",
            "input": "tools.mcp__node_repl__js({code: 'globalThis.sky = (await import(\\\"@oai/sky\\\")).sky; await sky.get_app_state({app: \\\"com.apple.QuickTimePlayerX\\\"})'})"
        ]
        precondition(ApprovalDetection.isInteractivePayload(computerUseEnvelope))
        precondition(
            ApprovalDetection.detail(for: "exec", interactivePayload: true) == "等待批准软件操作"
        )

        let ordinaryCommand: [String: Any] = [
            "type": "custom_tool_call",
            "name": "exec",
            "input": "swift build"
        ]
        precondition(!ApprovalDetection.isInteractivePayload(ordinaryCommand))
        precondition(ApprovalDetection.isInteractiveTool("node_repl"))

        // Some local builds serialize the wrapper without the mcp namespace;
        // the concrete browser marker must still make it an interactive call.
        let browserEnvelope: [String: Any] = [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": "call-browser-fixture",
            "input": "await browser.open(\"https://example.com\")"
        ]
        precondition(ApprovalDetection.isInteractivePayload(browserEnvelope))
        precondition(ApprovalDetection.isInteractiveTool("computer_use"))

        // Actual Codex desktop logs serialize Computer Use through a
        // function_call envelope owned by the CUA repl namespace.
        let cuaReplFunctionCall: [String: Any] = [
            "type": "function_call",
            "name": "js",
            "namespace": "mcp__cua_repl",
            "call_id": "call-cua-repl-fixture",
            "arguments": "await ghTab.playwright.getByRole('button', {name: 'Choose your files'}).click()"
        ]
        precondition(ApprovalDetection.isInteractivePayload(cuaReplFunctionCall))

        print("ApprovalDetectionSmoke: PASS")
    }
}
