import Foundation
import NordvaNotchCore

/// Follows each session's transcript and its subagents' transcripts as they grow, reading only
/// what was appended since the last look. Used from one serial queue only.
final class UsageTracker {
    private struct FileState {
        var offset: UInt64
        var partial = Data()
    }

    private struct Turn {
        let since: Double
        var meter: UsageMeter
        var files: [String: FileState] = [:]
        var agentFiles: Set<String> = []
    }

    /// A transcript can be tens of megabytes; a turn never starts further back than this.
    private static let window: UInt64 = 32 * 1024 * 1024
    private var turns: [String: Turn] = [:]

    func usage(for records: [SessionRecord], now: Double) -> [String: TurnUsage] {
        var result: [String: TurnUsage] = [:]
        for record in records {
            guard let start = record.turnStartedAt, let path = record.transcriptPath else { continue }
            // Only the current turn of sessions that are busy or stopped recently is worth reading.
            guard record.status == .working || now - record.updatedAt < 6 * 3600 else { continue }
            var turn = turns[record.id].flatMap { $0.since == start ? $0 : nil }
                ?? Turn(since: start, meter: UsageMeter(since: start))
            read(path, into: &turn, agent: false)
            if path.hasSuffix(".jsonl") {
                let folder = String(path.dropLast(".jsonl".count)) + "/subagents"
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
                    let file = folder + "/" + name
                    if turn.files[file] == nil {
                        let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
                        guard let modified, modified.timeIntervalSince1970 >= start else { continue }
                    }
                    read(file, into: &turn, agent: true)
                }
            }
            turn.meter.setAgents(turn.agentFiles.count)
            turns[record.id] = turn
            result[record.id] = turn.meter.usage
        }
        let live = Set(records.map(\.id))
        turns = turns.filter { live.contains($0.key) }
        return result
    }

    private func read(_ path: String, into turn: inout Turn, agent: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }

        var skipFirstLine = false
        var state: FileState
        if let known = turn.files[path], known.offset <= size {
            state = known
        } else {
            let start = agent || size <= Self.window ? 0 : size - Self.window
            state = FileState(offset: start)
            skipFirstLine = start > 0
        }
        guard size > state.offset else {
            turn.files[path] = state
            return
        }
        try? handle.seek(toOffset: state.offset)
        let chunk = (try? handle.read(upToCount: Int(size - state.offset))) ?? Data()
        state.offset = size

        var bytes = state.partial + chunk
        if skipFirstLine, let firstNewline = bytes.firstIndex(of: 0x0A) {
            bytes = Data(bytes[bytes.index(after: firstNewline)...])
        }
        // A line still being written stays for the next read.
        if let lastNewline = bytes.lastIndex(of: 0x0A) {
            state.partial = Data(bytes[bytes.index(after: lastNewline)...])
            bytes = Data(bytes[..<lastNewline])
        } else {
            state.partial = bytes
            bytes = Data()
        }

        var counted = false
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where turn.meter.ingest(line) {
            counted = true
        }
        if agent && counted { turn.agentFiles.insert(path) }
        turn.files[path] = state
    }
}
