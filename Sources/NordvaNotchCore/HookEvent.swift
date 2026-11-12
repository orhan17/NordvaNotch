import Foundation

/// One Claude Code hook call: the JSON on stdin plus the bits of the environment we care about.
public struct HookEvent: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case notification = "Notification"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case sessionEnd = "SessionEnd"
    }

    public var kind: Kind
    public var sessionID: String
    public var cwd: String = ""
    public var transcriptPath: String?
    public var sessionTitle: String?
    public var prompt: String?
    public var toolName: String?
    public var notificationType: String?
    public var message: String?
    public var lastAssistantMessage: String?
    public var source: String?
    public var error: String?
    /// Set when the event comes from a subagent rather than the main conversation.
    public var agentID: String?
    /// From Stop: work still running after the turn ended, as (agents, commands).
    public var background: (agents: Int, commands: Int)?
    public var entrypoint: String?
    public var hostSessionID: String?
    public var hostBundleID: String?

    public init(kind: Kind, sessionID: String) {
        self.kind = kind
        self.sessionID = sessionID
    }

    /// Returns nil for events NordvaNotch does not track and for payloads without a usable session id.
    public static func parse(_ json: [UInt8], environment: [String: String] = [:]) -> HookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json)),
              let payload = object as? [String: Any],
              let name = payload["hook_event_name"] as? String,
              let kind = Kind(rawValue: name),
              let sessionID = payload["session_id"] as? String,
              isSafeID(sessionID)
        else { return nil }

        func text(_ key: String) -> String? {
            guard let value = payload[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        var event = HookEvent(kind: kind, sessionID: sessionID)
        event.cwd = text("cwd") ?? ""
        event.transcriptPath = text("transcript_path")
        event.sessionTitle = text("session_title")
        event.prompt = text("prompt")
        event.toolName = text("tool_name")
        event.notificationType = text("notification_type")
        event.message = text("message")
        event.lastAssistantMessage = text("last_assistant_message")
        event.source = text("source") ?? text("reason")
        event.error = text("error") ?? text("error_message") ?? text("error_type")
        event.agentID = text("agent_id")
        if let tasks = payload["background_tasks"] as? [[String: Any]] {
            // Subagents, workflows, teammates and cloud sessions are agents; shells, monitors and MCP tasks are commands.
            let agentTypes: Set<String> = ["subagent", "workflow", "teammate", "cloud session"]
            let agents = tasks.filter { agentTypes.contains(($0["type"] as? String ?? "").lowercased()) }.count
            event.background = (agents, tasks.count - agents)
        }
        event.entrypoint = environment["CLAUDE_CODE_ENTRYPOINT"].flatMap { $0.isEmpty ? nil : $0 }
        event.hostSessionID = environment["CLAUDE_CODE_HOST_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        event.hostBundleID = environment["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
        return event
    }

    /// The id becomes a file name, so anything that could escape the sessions folder is rejected.
    public static func isSafeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
