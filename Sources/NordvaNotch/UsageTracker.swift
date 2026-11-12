import Foundation
import NordvaNotchCore

struct UsageSnapshot: Equatable {
    var turns: [String: TurnUsage] = [:]
    /// Every session and agent over the last five hours, at API prices.
    var windowCost = 0.0
    var windowCalls = 0
    /// `autoCompactWindow` from Claude Code's settings, if set.
    var configuredContext: Int?
    /// The plan's real limits, kept by the status line command; nil on API billing.
    var limits: PlanLimits?
    /// The five-hour limit now: the last report carried forward with the usage since.
    var fiveHour: LimitEstimate?
    /// Percent of the five-hour limit per dollar at API prices, from the last report that allowed it.
    var perDollar: Double?
}

/// Reads Claude Code transcripts as they grow, only the bytes appended since the last look, and
/// feeds each request to the turn of the session it belongs to and to the five-hour window.
/// Used from one serial queue only.
final class UsageTracker {
    static let windowLength: Double = 5 * 3600

    private struct FileState {
        var offset: UInt64
        var partial = Data()
    }

    private struct Turn {
        let since: Double
        var meter: UsageMeter
        var agentFiles: Set<String> = []
    }

    /// The first look at a file reads at most its last 64 MB: enough for five hours of any session.
    private static let tail: UInt64 = 64 * 1024 * 1024
    private let projects: String
    private let settings: String
    private var files: [String: FileState] = [:]
    private var turns: [String: Turn] = [:]
    private var window = RollingWindow(length: UsageTracker.windowLength)
    private var recent: [String] = []
    private var lastScan = 0.0
    private var settingsCache: (modified: Date, value: Int?)?
    private var perDollar: Double? = {
        let saved = UserDefaults.standard.double(forKey: "limitPerDollar")
        return saved > 0 ? saved : nil
    }()

    init(home: String = NSHomeDirectory()) {
        projects = home + "/.claude/projects"
        settings = home + "/.claude/settings.json"
    }

    func refresh(records: [SessionRecord], now: Double) -> UsageSnapshot {
        let windowStart = now - Self.windowLength

        // Which file belongs to which session's current turn.
        var owners: [String: (id: String, main: Bool)] = [:]
        for record in records {
            guard let start = record.turnStartedAt, let path = record.transcriptPath,
                  record.status == .working || now - record.updatedAt < 6 * 3600
            else { continue }
            if turns[record.id]?.since != start {
                // A new turn begins after everything already read, so read positions are kept.
                turns[record.id] = Turn(since: start, meter: UsageMeter(since: start))
            }
            owners[path] = (record.id, true)
            for file in subagentFiles(of: path) where owners[file] == nil {
                if files[file] == nil, modified(file) < min(start, windowStart) { continue }
                owners[file] = (record.id, false)
            }
        }
        let live = Set(records.map(\.id))
        turns = turns.filter { live.contains($0.key) }

        // Every transcript touched within the window counts, sessions without hooks included.
        if now - lastScan > 60 {
            recent = scanRecent(since: windowStart)
            lastScan = now
        }

        let active = Set(owners.keys).union(recent)
        for path in active {
            let owner = owners[path]
            let turnStart = owner.flatMap { turns[$0.id]?.since } ?? windowStart
            let notBefore = TranscriptLine.stamp(min(windowStart, turnStart))
            guard let text = readNew(path) else { continue }
            for line in text.split(separator: "\n") {
                guard let request = TranscriptLine.request(line, notBefore: notBefore) else { continue }
                if request.time >= windowStart { window.add(request) }
                if let owner, var turn = turns[owner.id] {
                    if turn.meter.add(request, main: owner.main), !owner.main { turn.agentFiles.insert(path) }
                    turns[owner.id] = turn
                }
            }
        }
        files = files.filter { active.contains($0.key) }
        window.prune(now: now)

        var snapshot = UsageSnapshot(
            windowCost: window.cost(now: now), windowCalls: window.calls(now: now),
            configuredContext: configuredContext()
        )
        if let data = FileManager.default.contents(atPath: PlanLimits.defaultPath),
           let limits = PlanLimits.decode([UInt8](data)) {
            snapshot.limits = limits
            if let five = limits.fiveHour {
                let windowStart = five.resetsAt - PlanLimits.fiveHours
                // The report's window must still be in memory to read the rate off it.
                if windowStart >= now - Self.windowLength,
                   let rate = LimitShare.perDollar(percent: five.percent, windowCost: window.cost(from: windowStart, to: limits.updatedAt)) {
                    perDollar = rate
                    UserDefaults.standard.set(rate, forKey: "limitPerDollar")
                }
                var nextWindow: (start: Double, cost: Double)?
                if five.resetsAt <= now, var start = window.firstRequest(atOrAfter: five.resetsAt) {
                    while start + PlanLimits.fiveHours <= now, let later = window.firstRequest(atOrAfter: start + PlanLimits.fiveHours) {
                        start = later
                    }
                    nextWindow = (start, window.cost(since: start))
                }
                snapshot.fiveHour = LimitEstimate.fiveHour(
                    limits, now: now, costSinceReport: window.cost(from: limits.updatedAt, to: now),
                    perDollar: perDollar, nextWindow: nextWindow
                )
            }
            snapshot.perDollar = perDollar
        }
        for (id, var turn) in turns {
            turn.meter.setAgents(turn.agentFiles.count)
            turns[id] = turn
            snapshot.turns[id] = turn.meter.usage
        }
        return snapshot
    }

    // MARK: Files

    private func subagentFiles(of transcript: String) -> [String] {
        guard transcript.hasSuffix(".jsonl") else { return [] }
        let folder = String(transcript.dropLast(".jsonl".count)) + "/subagents"
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .map { folder + "/" + $0 }
    }

    /// `~/.claude/projects/<project>/<session>.jsonl` and `<project>/<session>/subagents/agent-*.jsonl`.
    private func scanRecent(since: Double) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        for project in (try? manager.contentsOfDirectory(atPath: projects)) ?? [] {
            let folder = projects + "/" + project
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                if name.hasSuffix(".jsonl") {
                    if modified(path) >= since { found.append(path) }
                } else if !name.contains(".") {
                    for agent in subagentFiles(of: path + ".jsonl") where modified(agent) >= since {
                        found.append(agent)
                    }
                }
            }
        }
        return found
    }

    private func modified(_ path: String) -> Double {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return Double(info.st_mtimespec.tv_sec)
    }

    /// The complete lines appended since the last call; a line still being written waits.
    private func readNew(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var skipFirstLine = false
        var state: FileState
        if let known = files[path], known.offset <= size {
            state = known
        } else {
            let start = size > Self.tail ? size - Self.tail : 0
            state = FileState(offset: start)
            skipFirstLine = start > 0
        }
        guard size > state.offset else {
            files[path] = state
            return nil
        }
        try? handle.seek(toOffset: state.offset)
        let chunk = (try? handle.read(upToCount: Int(size - state.offset))) ?? Data()
        state.offset = size

        var bytes = state.partial + chunk
        if skipFirstLine, let firstNewline = bytes.firstIndex(of: 0x0A) {
            bytes = Data(bytes[bytes.index(after: firstNewline)...])
        }
        if let lastNewline = bytes.lastIndex(of: 0x0A) {
            state.partial = Data(bytes[bytes.index(after: lastNewline)...])
            bytes = Data(bytes[..<lastNewline])
        } else {
            state.partial = bytes
            bytes = Data()
        }
        files[path] = state
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private func configuredContext() -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: settings),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        if let cache = settingsCache, cache.modified == modified { return cache.value }
        var value: Int?
        if let data = FileManager.default.contents(atPath: settings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value = (object["autoCompactWindow"] as? NSNumber)?.intValue
        }
        settingsCache = (modified, value)
        return value
    }
}
