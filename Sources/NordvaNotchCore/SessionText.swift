import Foundation

/// What the island shows of a turn: the prompt that started it and the reply that ended it,
/// as plain text.
public enum SessionText {
    /// The person's words: no system reminders the host adds to the prompt, no paste markers.
    /// Nil when nothing of theirs is left, as when a background task reports back.
    public static func prompt(_ raw: String) -> String? {
        var text = raw
        while let start = text.range(of: "<system-reminder>") {
            let end = text.range(of: "</system-reminder>", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(start.lowerBound..<end)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<task-notification") { return nil }
        text = trimmed.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: " ", options: .regularExpression)
        let line = collapse(text)
        return line.isEmpty ? nil : line
    }

    /// Markdown to plain lines: no emphasis, code marks, headings, rules or link targets;
    /// list items keep a bullet, table rows become "a · b"; blank lines and code blocks go.
    public static func reply(_ markdown: String, limit: Int) -> String? {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode || line.isEmpty { continue }
            if line.count >= 3, line.allSatisfy({ "-*_ ".contains($0) }) { continue }
            while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = "• " + line.dropFirst(marker.count)
            }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                line = cells.joined(separator: " · ")
            }
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for mark in ["**", "__", "~~", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            line = collapse(line)
            if !line.isEmpty { lines.append(line) }
        }
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The reply on one line, for places with room for one.
    public static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
