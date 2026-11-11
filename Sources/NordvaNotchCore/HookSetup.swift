import Foundation

/// The Claude Code hooks NordvaNotch needs in `~/.claude/settings.json`.
public enum HookSetup {
    public struct Entry: Equatable, Sendable {
        public var event: String
        public var matcher: String?
    }

    public static let entries: [Entry] = [
        Entry(event: "SessionStart"),
        Entry(event: "UserPromptSubmit"),
        Entry(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode"),
        Entry(event: "PermissionRequest"),
        Entry(event: "PostToolUse"),
        Entry(event: "PostToolUseFailure"),
        Entry(event: "Notification"),
        Entry(event: "Stop"),
        Entry(event: "StopFailure"),
        Entry(event: "SessionEnd"),
    ]

    public static let helperName = "notch-hook"
    public static let timeoutSeconds = 5

    /// `|| true` keeps the exit code at 0 even if the app was moved or deleted.
    public static func command(helperPath: String) -> String {
        let safe = helperPath.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
        let quoted = safe ? helperPath : "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quoted + " || true"
    }

    public static func isInstalled(settingsText: String) -> Bool {
        settingsText.contains("/\(helperName)")
    }

    /// The `hooks` object to merge into settings.json, pretty-printed like Claude Code writes it.
    public static func snippet(helperPath: String) -> String {
        let command = jsonString(command(helperPath: helperPath))
        var lines = ["{", "  \"hooks\": {"]
        for (index, entry) in entries.enumerated() {
            lines.append("    \"\(entry.event)\": [")
            lines.append("      {")
            if let matcher = entry.matcher {
                lines.append("        \"matcher\": \(jsonString(matcher)),")
            }
            lines.append("        \"hooks\": [")
            lines.append("          {")
            lines.append("            \"type\": \"command\",")
            lines.append("            \"command\": \(command),")
            lines.append("            \"async\": true,")
            lines.append("            \"timeout\": \(timeoutSeconds)")
            lines.append("          }")
            lines.append("        ]")
            lines.append("      }")
            lines.append("    ]" + (index == entries.count - 1 ? "" : ","))
        }
        lines.append("  }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension HookSetup.Entry {
    init(event: String) {
        self.init(event: event, matcher: nil)
    }
}
