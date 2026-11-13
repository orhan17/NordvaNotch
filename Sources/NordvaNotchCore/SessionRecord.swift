import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case idle
    case working
    case waiting
    case done
    case failed

    /// Statuses that are worth expanding the island for.
    public var wantsAttention: Bool {
        self == .waiting || self == .done || self == .failed
    }
}

public enum WaitReason: String, Codable, Sendable {
    case permission
    case question
    case plan
    case input
}

/// What the hook writes to `sessions/<id>.json` and the app reads back.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var id: String
    public var status: SessionStatus
    public var waitReason: WaitReason?
    /// Tool name for a permission request, error text for a failure.
    public var detail: String?
    public var cwd: String
    public var transcriptPath: String?
    public var title: String?
    public var prompt: String?
    public var reply: String?
    public var entrypoint: String?
    public var hostSessionID: String?
    public var hostBundleID: String?
    /// When the current turn began: the last prompt. Its duration and usage are measured from here.
    public var turnStartedAt: Double?
    /// Agents and commands still running when the turn ended, from Stop.
    public var backgroundAgents: Int?
    public var backgroundCommands: Int?
    /// What those are, as "type: description", at most five.
    public var backgroundTasks: [String]?
    public var createdAt: Double
    public var updatedAt: Double
    /// When `status` (or the reason for waiting) last changed; the app alerts once per value.
    public var statusSince: Double

    public init(id: String, status: SessionStatus, cwd: String, at time: Double) {
        self.id = id
        self.status = status
        self.cwd = cwd
        createdAt = time
        updatedAt = time
        statusSince = time
    }

    public enum Update: Equatable, Sendable {
        case write(SessionRecord)
        case remove
        case ignore
    }

    static let promptLimit = 200
    static let replyLimit = 600
    public static let heartbeat: Double = 60

    /// The state machine. Pure, so the hook and the tests share it.
    public static func apply(_ event: HookEvent, to existing: SessionRecord?, at now: Double) -> Update {
        // `claude -p` and Agent SDK apps (sdk-cli, sdk-ts, sdk-py) are scripts, not sessions anyone waits on.
        if let entrypoint = event.entrypoint, entrypoint.hasPrefix("sdk-") { return .ignore }
        // Async hooks can finish out of order; an older event must not overwrite a newer state.
        if let existing, now < existing.updatedAt { return .ignore }
        // Subagents report with the parent's session id; their tool calls say nothing about the main turn.
        if event.agentID != nil, event.kind != .permissionRequest, event.kind != .notification { return .ignore }

        var record = existing ?? SessionRecord(id: event.sessionID, status: .idle, cwd: event.cwd, at: now)
        let before = (record.status, record.waitReason)

        switch event.kind {
        case .sessionStart:
            break
        case .userPromptSubmit:
            record.status = .working
            record.waitReason = nil
            record.detail = nil
            record.reply = nil
            record.turnStartedAt = now
            record.backgroundAgents = nil
            record.backgroundCommands = nil
            record.backgroundTasks = nil
            // A background task reporting back has no words of the person: the earlier prompt stays.
            if let prompt = event.prompt.flatMap(SessionText.prompt) { record.prompt = clip(prompt, to: promptLimit) }
        case .preToolUse:
            switch event.toolName {
            case "AskUserQuestion":
                record.status = .waiting
                record.waitReason = .question
            case "ExitPlanMode":
                record.status = .waiting
                record.waitReason = .plan
            default:
                record.status = .working
                record.waitReason = nil
            }
            record.detail = nil
        case .permissionRequest:
            // The desktop app routes its question and plan tools through the permission flow too.
            record.status = .waiting
            switch event.toolName {
            case "AskUserQuestion":
                record.waitReason = .question
                record.detail = nil
            case "ExitPlanMode":
                record.waitReason = .plan
                record.detail = nil
            default:
                record.waitReason = .permission
                record.detail = event.toolName
            }
        case .postToolUse, .postToolUseFailure:
            // Every tool call lands here; rewrite the file only when something changes,
            // plus a heartbeat a minute so a long turn does not look stalled.
            if let existing, existing.status == .working, now - existing.updatedAt < heartbeat { return .ignore }
            record.status = .working
            record.waitReason = nil
            record.detail = nil
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                // PermissionRequest or PreToolUse usually got here first and know more; keep that.
                guard record.status != .waiting else { return .ignore }
                record.status = .waiting
                record.waitReason = .permission
                record.detail = event.message.map { clip($0, to: promptLimit) }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                record.status = .waiting
                record.waitReason = .input
                record.detail = event.message.map { clip($0, to: promptLimit) }
            case "idle_prompt":
                // Normally Stop already said so; this covers a turn whose Stop hook never ran.
                guard record.status == .working else { return .ignore }
                record.status = .done
                record.waitReason = nil
            default:
                return .ignore
            }
        case .stop:
            record.status = .done
            record.waitReason = nil
            record.detail = nil
            record.reply = event.lastAssistantMessage.flatMap { SessionText.reply($0, limit: replyLimit) }
            record.backgroundAgents = event.background.map(\.agents)
            record.backgroundCommands = event.background.map(\.commands)
            record.backgroundTasks = event.backgroundNames.isEmpty ? nil : event.backgroundNames
        case .stopFailure:
            record.status = .failed
            record.waitReason = nil
            record.detail = event.error.map { clip($0, to: promptLimit) }
        case .sessionEnd:
            return existing == nil ? .ignore : .remove
        }

        if !event.cwd.isEmpty { record.cwd = event.cwd }
        if let path = event.transcriptPath { record.transcriptPath = path }
        if let title = event.sessionTitle { record.title = clip(title, to: 120) }
        if let value = event.entrypoint { record.entrypoint = value }
        if let value = event.hostSessionID { record.hostSessionID = value }
        if let value = event.hostBundleID { record.hostBundleID = value }
        record.updatedAt = now
        if before != (record.status, record.waitReason) || event.kind == .stop {
            record.statusSince = now
        }
        return .write(record)
    }

    /// One line, collapsed whitespace, cut on a character boundary with an ellipsis.
    public static func clip(_ text: String, to limit: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public func encoded() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? [UInt8](encoder.encode(self))) ?? []
    }

    public static func decode(_ bytes: [UInt8]) -> SessionRecord? {
        try? JSONDecoder().decode(SessionRecord.self, from: Data(bytes))
    }
}
