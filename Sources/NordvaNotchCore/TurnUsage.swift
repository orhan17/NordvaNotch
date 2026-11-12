import Foundation

/// What one turn of a session has used so far: the main conversation plus its subagents.
public struct TurnUsage: Equatable, Sendable {
    public var calls = 0
    public var input = 0
    public var output = 0
    public var write5m = 0
    public var write1h = 0
    public var read = 0
    /// What the same requests would cost at Anthropic API prices, in dollars.
    public var cost = 0.0
    /// Requests from a model missing in the price list; their tokens count, their cost does not.
    public var unpriced = 0
    public var agents = 0
    /// Prompt size of the latest request in the main conversation: how full its context is.
    public var context = 0
    public var model: String?

    public init() {}

    public var tokens: Int { input + output + write5m + write1h + read }
}

/// One request to the model, as a transcript line records it.
public struct UsageRequest: Equatable, Sendable {
    public var id: String
    public var time: Double
    public var model: String
    public var input: Int
    public var output: Int
    public var write5m: Int
    public var write1h: Int
    public var read: Int
    /// nil when the model is missing in the price list.
    public var cost: Double?

    public var tokens: Int { input + output + write5m + write1h + read }
    /// Everything the model was given: the context this request filled.
    public var prompt: Int { input + write5m + write1h + read }
}

/// API prices per million tokens. A Claude subscription does not bill per token, but the same
/// work counts against its limits, so the dollar figure is a fair measure of how heavy a turn is.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

public enum Pricing {
    /// Anthropic API list prices, November 2026. Longer ids first: "claude-fable-5-2" before "claude-fable-5".
    static let table: [(id: String, price: ModelPrice)] = [
        ("claude-fable-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-mythos-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.10)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        table.first { model.hasPrefix($0.id) }?.price
    }

    /// Cache writes cost 1.25x the input price for the 5-minute TTL and 2x for the 1-hour one;
    /// fast mode doubles everything. Claude Haiku 5.5 costs 5x more past a 100K-token prompt.
    public static func cost(
        model: String, input: Int, output: Int, write5m: Int, write1h: Int, read: Int, fast: Bool
    ) -> Double? {
        guard let price = price(for: model) else { return nil }
        var factor = fast ? 2.0 : 1.0
        if model.hasPrefix("claude-haiku-5-5"), input + write5m + write1h + read > 100_000 { factor *= 5 }
        let perToken = factor / 1_000_000
        let inputSide = Double(input) + Double(write5m) * 1.25 + Double(write1h) * 2
        return (inputSide * price.input + Double(output) * price.output + Double(read) * price.cacheRead) * perToken
    }
}

public enum TranscriptLine {
    /// The request an assistant line records, or nil for any other line and for lines older than
    /// `notBefore` (an ISO 8601 UTC stamp). Claude Code writes one line per content block, each
    /// repeating the message's usage, so callers count a message once by `id`.
    public static func request(_ line: Substring, notBefore: String) -> UsageRequest? {
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }
        // Timestamps are fixed-width UTC, so comparing the text skips old lines without parsing them.
        if let stamp = timestamp(in: line), stamp < notBefore { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let stamp = object["timestamp"] as? String, stamp >= notBefore,
              let time = parse(stamp),
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              let fields = message["usage"] as? [String: Any]
        else { return nil }

        func int(_ dict: [String: Any]?, _ key: String) -> Int {
            (dict?[key] as? NSNumber)?.intValue ?? 0
        }
        let breakdown = fields["cache_creation"] as? [String: Any]
        var request = UsageRequest(
            id: id, time: time, model: message["model"] as? String ?? "",
            input: int(fields, "input_tokens"), output: int(fields, "output_tokens"),
            write5m: int(breakdown, "ephemeral_5m_input_tokens"), write1h: int(breakdown, "ephemeral_1h_input_tokens"),
            read: int(fields, "cache_read_input_tokens"), cost: nil
        )
        if breakdown == nil { request.write5m = int(fields, "cache_creation_input_tokens") }
        request.cost = Pricing.cost(
            model: request.model, input: request.input, output: request.output,
            write5m: request.write5m, write1h: request.write1h, read: request.read,
            fast: fields["speed"] as? String == "fast"
        )
        return request
    }

    static func timestamp(in line: Substring) -> String? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func stamp(_ time: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: time))
    }

    static func parse(_ stamp: String) -> Double? {
        formatter.date(from: stamp)?.timeIntervalSince1970
    }
}

/// Adds up the requests of one turn.
public struct UsageMeter: Sendable {
    public let since: Double
    public private(set) var usage = TurnUsage()
    private var seen = Set<String>()
    public let sinceStamp: String

    public init(since: Double) {
        self.since = since
        sinceStamp = TranscriptLine.stamp(since)
    }

    /// Returns true when the line added a request.
    @discardableResult
    public mutating func ingest(_ line: Substring, main: Bool = true) -> Bool {
        guard let request = TranscriptLine.request(line, notBefore: sinceStamp) else { return false }
        return add(request, main: main)
    }

    /// `main` is false for a subagent's request, which does not tell how full the session's context is.
    @discardableResult
    public mutating func add(_ request: UsageRequest, main: Bool) -> Bool {
        guard request.time >= since, !seen.contains(request.id) else { return false }
        seen.insert(request.id)
        usage.calls += 1
        usage.input += request.input
        usage.output += request.output
        usage.read += request.read
        usage.write5m += request.write5m
        usage.write1h += request.write1h
        if let cost = request.cost { usage.cost += cost } else { usage.unpriced += 1 }
        if main {
            usage.context = request.prompt
            usage.model = request.model
        }
        return true
    }

    public mutating func setAgents(_ count: Int) {
        usage.agents = count
    }
}

/// Usage across every session over a sliding window: the subscription limits work on five hours.
public struct RollingWindow: Sendable {
    public let length: Double
    private var requests: [String: (time: Double, cost: Double)] = [:]

    public init(length: Double) {
        self.length = length
    }

    public mutating func add(_ request: UsageRequest) {
        requests[request.id] = (request.time, request.cost ?? 0)
    }

    public mutating func prune(now: Double) {
        requests = requests.filter { now - $0.value.time < length }
    }

    public func cost(now: Double) -> Double {
        requests.values.filter { now - $0.time < length }.reduce(0) { $0 + $1.cost }
    }

    public func calls(now: Double) -> Int {
        requests.values.filter { now - $0.time < length }.count
    }
}

public enum ContextWindow {
    /// The window a session's context is measured against: `autoCompactWindow` from Claude Code's
    /// settings when set, otherwise the model's own (1M on current models, 200K on Haiku 4.5 and older).
    public static func size(model: String?, configured: Int?) -> Int {
        if let configured, configured > 0 { return configured }
        guard let model else { return 1_000_000 }
        let small = ["claude-haiku-4", "claude-3", "claude-sonnet-4-5", "claude-opus-4-5", "claude-opus-4-1", "claude-opus-4-0", "claude-sonnet-4-0"]
        return small.contains { model.hasPrefix($0) } ? 200_000 : 1_000_000
    }

    public static func percent(_ tokens: Int, of window: Int) -> Int {
        guard window > 0 else { return 0 }
        return Int((Double(tokens) / Double(window) * 100).rounded())
    }
}

public enum UsageText {
    /// "$0.42", "$3.1", "$12"; under a cent shows as "<$0.01".
    public static func cost(_ dollars: Double) -> String {
        if dollars < 0.01 { return "<$0.01" }
        if dollars < 1 { return "$" + fixed(dollars, 2) }
        if dollars < 10 { return "$" + fixed(dollars, 1) }
        return "$\(Int(dollars.rounded()))"
    }

    /// "820", "45k", "3.4M".
    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        return fixed(Double(count) / 1_000_000, 1) + "M"
    }

    /// "45s", "12m", "1h 05m".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = s % 3600 / 60
        return "\(s / 3600)h \(m < 10 ? "0\(m)" : "\(m)")m"
    }

    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
