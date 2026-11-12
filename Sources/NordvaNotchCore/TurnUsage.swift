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

    public init() {}

    public var tokens: Int { input + output + write5m + write1h + read }
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

/// Adds up the assistant messages of one turn from transcript lines. Claude Code writes one line
/// per content block, each repeating the message's usage, so messages are counted once by id.
public struct UsageMeter: Sendable {
    public let since: Double
    public private(set) var usage = TurnUsage()
    private var seen = Set<String>()
    private let sinceStamp: String

    public init(since: Double) {
        self.since = since
        sinceStamp = Self.stamp(since)
    }

    /// Returns true when the line added a request.
    @discardableResult
    public mutating func ingest(_ line: Substring) -> Bool {
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return false }
        // Timestamps are fixed-width UTC, so comparing the text skips old lines without parsing them.
        if let stamp = Self.timestamp(in: line), stamp < sinceStamp { return false }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              let fields = message["usage"] as? [String: Any],
              !seen.contains(id)
        else { return false }
        if let stamp = object["timestamp"] as? String, stamp < sinceStamp { return false }
        seen.insert(id)

        func int(_ dict: [String: Any]?, _ key: String) -> Int {
            (dict?[key] as? NSNumber)?.intValue ?? 0
        }
        let input = int(fields, "input_tokens")
        let output = int(fields, "output_tokens")
        let read = int(fields, "cache_read_input_tokens")
        let breakdown = fields["cache_creation"] as? [String: Any]
        var write5m = int(breakdown, "ephemeral_5m_input_tokens")
        let write1h = int(breakdown, "ephemeral_1h_input_tokens")
        if breakdown == nil { write5m = int(fields, "cache_creation_input_tokens") }

        usage.calls += 1
        usage.input += input
        usage.output += output
        usage.read += read
        usage.write5m += write5m
        usage.write1h += write1h
        let model = message["model"] as? String ?? ""
        let fast = fields["speed"] as? String == "fast"
        if let cost = Pricing.cost(model: model, input: input, output: output, write5m: write5m, write1h: write1h, read: read, fast: fast) {
            usage.cost += cost
        } else {
            usage.unpriced += 1
        }
        return true
    }

    public mutating func setAgents(_ count: Int) {
        usage.agents = count
    }

    static func timestamp(in line: Substring) -> String? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func stamp(_ time: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: time))
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
