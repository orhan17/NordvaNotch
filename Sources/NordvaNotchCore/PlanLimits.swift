import Foundation

/// The subscription's usage limits, as Claude Code reports them to a status line command
/// (`rate_limits` in its JSON): the same numbers `/usage` shows. Pro and Max plans only.
public struct PlanLimits: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var percent: Double
        public var resetsAt: Double

        public init(percent: Double, resetsAt: Double) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var updatedAt: Double
    /// Which Claude Code wrote it last (`cli`, `claude-desktop`), for diagnosis.
    public var source: String?

    public init(fiveHour: Window?, sevenDay: Window?, updatedAt: Double) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }

    public static let fiveHours: Double = 5 * 3600

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/NordvaNotch/limits.json"
    }

    /// A window counts until it resets; after that the next one starts with the next message.
    public func active(_ window: Window?, now: Double) -> Window? {
        guard let window, window.resetsAt > now else { return nil }
        return window
    }

    public func encoded() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? [UInt8](encoder.encode(self))) ?? []
    }

    public static func decode(_ bytes: [UInt8]) -> PlanLimits? {
        try? JSONDecoder().decode(PlanLimits.self, from: Data(bytes))
    }
}

/// What a status line command receives on stdin and what NordvaNotch prints back.
public enum StatusLine {
    public struct Input: Equatable, Sendable {
        public var limits: PlanLimits? = nil
        public var contextPercent: Int? = nil
    }

    public static func parse(_ bytes: [UInt8], at now: Double) -> Input {
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return Input()
        }
        func window(_ key: String) -> PlanLimits.Window? {
            guard let limits = object["rate_limits"] as? [String: Any],
                  let window = limits[key] as? [String: Any],
                  let percent = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (window["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return PlanLimits.Window(percent: percent, resetsAt: resets)
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        let limits = five == nil && seven == nil ? nil : PlanLimits(fiveHour: five, sevenDay: seven, updatedAt: now)
        let context = ((object["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.intValue
        return Input(limits: limits, contextPercent: context)
    }

    /// "5h 58% · 7d 16% · ctx 5%", for the bottom of the terminal.
    public static func text(for input: Input, now: Double) -> String {
        var parts: [String] = []
        if let limits = input.limits {
            if let five = limits.active(limits.fiveHour, now: now) { parts.append("5h \(Int(five.percent.rounded()))%") }
            if let seven = limits.active(limits.sevenDay, now: now) { parts.append("7d \(Int(seven.percent.rounded()))%") }
        }
        if let context = input.contextPercent { parts.append("ctx \(context)%") }
        return parts.joined(separator: " · ")
    }
}

/// The five-hour limit now. Claude Code reports it only to a status line, which the terminal draws
/// and the desktop app does not, so the last report is carried forward with the usage since,
/// at the rate the report itself shows (percent per dollar at API prices).
public struct LimitEstimate: Equatable, Sendable {
    public var percent: Double
    public var resetsAt: Double
    /// Straight from Claude Code, not carried forward.
    public var exact: Bool

    public init(percent: Double, resetsAt: Double, exact: Bool) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.exact = exact
    }

    /// A report this fresh is shown as it is.
    public static let freshFor: Double = 120

    /// - Parameters:
    ///   - costSinceReport: usage after the report, at API prices.
    ///   - perDollar: percent of the limit per dollar, from the report.
    ///   - nextWindow: for a window that has reset: when the next one began (its first request)
    ///     and what it has cost since.
    public static func fiveHour(
        _ limits: PlanLimits, now: Double, costSinceReport: Double, perDollar: Double?,
        nextWindow: (start: Double, cost: Double)?
    ) -> LimitEstimate? {
        guard let five = limits.fiveHour else { return nil }
        if five.resetsAt > now {
            let fresh = now - limits.updatedAt < freshFor
            let added = perDollar.map { costSinceReport * $0 } ?? 0
            return LimitEstimate(percent: min(100, five.percent + added), resetsAt: five.resetsAt, exact: fresh || added < 0.5)
        }
        // The reported window is over; the next one started with its first request.
        guard let next = nextWindow, let perDollar, next.start + PlanLimits.fiveHours > now else { return nil }
        return LimitEstimate(
            percent: min(100, next.cost * perDollar), resetsAt: next.start + PlanLimits.fiveHours, exact: false
        )
    }
}

/// A turn's share of the five-hour limit. Claude Code reports only the window's total, so the
/// share is estimated: what the window has used so far, weighted by API prices, is matched to the
/// real percentage, and the turn gets its part in proportion. Anthropic does not publish how it
/// weighs models, and chat in the Claude apps counts too, so this is an estimate.
public enum LimitShare {
    /// Percent of the five-hour limit per dollar at API prices; nil until there is enough to go on.
    public static func perDollar(percent: Double, windowCost: Double) -> Double? {
        guard percent >= 2, windowCost >= 1 else { return nil }
        return percent / windowCost
    }

    public static func percent(cost: Double, perDollar: Double) -> Double {
        cost * perDollar
    }

    /// "<1%", "3%", "12%".
    public static func text(_ percent: Double) -> String {
        percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}
