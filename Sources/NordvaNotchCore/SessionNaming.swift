import Foundation

public enum SessionNaming {
    /// The folder a session works in. Worktrees made by Claude live in
    /// `<repo>/.claude/worktrees/<random-name>`, where the repo is the useful part.
    public static func projectName(cwd: String, home: String) -> String {
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { return "Unknown" }
        if path == home { return "~" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let marker = parts.lastIndex(of: ".claude"), marker > 0,
           parts.indices.contains(marker + 1), parts[marker + 1] == "worktrees" {
            return parts[marker - 1]
        }
        return parts.last ?? "/"
    }

    /// The latest session title written to a transcript: the name the Claude desktop app shows
    /// in its sidebar, or the one set with /rename in the CLI. Takes the tail of the file.
    public static func customTitle(inTranscriptTail tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"custom-title\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "custom-title",
                  let title = object["customTitle"] as? String
            else { continue }
            let clean = SessionRecord.clip(title, to: 120)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    /// Title first, then the opening prompt, then the folder.
    public static func displayTitle(of record: SessionRecord, transcriptTitle: String?, home: String) -> String {
        if let title = record.title, !title.isEmpty { return title }
        if let title = transcriptTitle, !title.isEmpty { return title }
        if let prompt = record.prompt, !prompt.isEmpty { return SessionRecord.clip(prompt, to: 60) }
        return projectName(cwd: record.cwd, home: home)
    }

    public static func statusText(of record: SessionRecord) -> String {
        switch record.status {
        case .idle: return "Ready"
        case .working: return "Working"
        case .done: return backgroundText(of: record).map { "Finished · \($0)" } ?? "Finished"
        case .failed: return record.detail.map { "Failed: \($0)" } ?? "Failed"
        case .waiting:
            switch record.waitReason {
            case .permission: return record.detail.map { "Needs permission: \($0)" } ?? "Needs permission"
            case .question: return "Asks you a question"
            case .plan: return "Waits for plan approval"
            case .input, .none: return "Waits for you"
            }
        }
    }
}

extension SessionNaming {
    /// "2 agents still running", "1 agent and 1 command still running"; nil when nothing runs.
    public static func backgroundText(of record: SessionRecord) -> String? {
        let agents = record.backgroundAgents ?? 0
        let commands = record.backgroundCommands ?? 0
        guard agents + commands > 0 else { return nil }
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        if commands > 0 { parts.append(commands == 1 ? "1 command" : "\(commands) commands") }
        return parts.joined(separator: " and ") + " still running"
    }
}

public enum TimeText {
    /// "now", "42s", "5m", "3h", "2d".
    public static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 10 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// "4:05", "1:02:03". Rounds up so a timer never shows 0:00 while still running.
    public static func countdown(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }
}

extension TimeText {
    /// Fits a narrow wing: "4:05", "59:59", then "1h02".
    public static func shortCountdown(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        guard total >= 3600 else { return countdown(seconds) }
        let m = total % 3600 / 60
        return "\(total / 3600)h\(m < 10 ? "0\(m)" : "\(m)")"
    }
}

public enum SessionLink {
    /// The Claude desktop app opens one of its local sessions with this link
    /// (the same check the app does: `local_` plus up to 64 letters, digits and dashes).
    public static func desktopURL(for record: SessionRecord) -> String? {
        guard record.entrypoint == "claude-desktop", let id = record.hostSessionID, id.hasPrefix("local_") else { return nil }
        let rest = id.dropFirst("local_".count)
        guard (1...64).contains(rest.count),
              rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return "claude://code/continue?session=\(id)"
    }
}
