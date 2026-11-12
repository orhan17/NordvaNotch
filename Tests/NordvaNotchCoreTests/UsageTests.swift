import Testing
@testable import NordvaNotchCore

@Suite struct Usage {
    // 2026-11-12T07:00:00Z
    let start = 1_794_466_800.0

    func line(id: String, ts: String, model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0,
              write5m: Int = 0, write1h: Int = 0, read: Int = 0, speed: String? = nil) -> Substring {
        let speedField = speed.map { #","speed":"\#($0)""# } ?? ""
        return Substring(#"""
        {"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)}\#(speedField)}}}
        """#)
    }

    @Test func pricesMatchTheListAndWeightCacheAndOutput() {
        // Opus 5.5: $4 in, $20 out, $0.20 cache read; 1h write = 2x input, 5m write = 1.25x.
        let cost = Pricing.cost(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000,
                                write5m: 1_000_000, write1h: 1_000_000, read: 1_000_000, fast: false)!
        #expect(abs(cost - (4 + 20 + 5 + 8 + 0.20)) < 0.0001)
        let fast = Pricing.cost(model: "claude-opus-5-5", input: 0, output: 1_000_000, write5m: 0, write1h: 0, read: 0, fast: true)!
        #expect(abs(fast - 40) < 0.0001)
        #expect(Pricing.price(for: "claude-fable-5-2")?.cacheRead == 0.20)
        #expect(Pricing.price(for: "claude-fable-5")?.cacheRead == 1.00)
        #expect(Pricing.price(for: "claude-opus-5-5[1m]")?.input == 4)
        #expect(Pricing.price(for: "<synthetic>") == nil)
        let longHaiku = Pricing.cost(model: "claude-haiku-5-5", input: 200_000, output: 0, write5m: 0, write1h: 0, read: 0, fast: false)!
        #expect(abs(longHaiku - 0.10) < 0.0001)
    }

    @Test func countsEachMessageOnceAndOnlyFromTheTurn() {
        var meter = UsageMeter(since: start)
        let before = line(id: "m0", ts: "2026-11-12T06:59:59.999Z", output: 999)
        let first = line(id: "m1", ts: "2026-11-12T07:00:01.000Z", input: 10, output: 100, write1h: 1000, read: 50_000)
        let repeated = line(id: "m1", ts: "2026-11-12T07:00:01.200Z", input: 10, output: 100, write1h: 1000, read: 50_000)
        let haiku = line(id: "m2", ts: "2026-11-12T07:00:05.000Z", model: "claude-haiku-5-5", output: 1000)
        let unknown = line(id: "m3", ts: "2026-11-12T07:00:06.000Z", model: "<synthetic>", output: 5)
        let counted = [before, first, repeated, haiku, unknown,
                       #"{"type":"user","timestamp":"2026-11-12T07:00:02.000Z","message":{"content":"usage"}}"#]
            .map { meter.ingest($0) }
        #expect(counted == [false, true, false, true, true, false])
        let u = meter.usage
        #expect(u.calls == 3)
        #expect(u.output == 1105)
        #expect(u.write1h == 1000)
        #expect(u.read == 50_000)
        #expect(u.tokens == 10 + 1105 + 1000 + 50_000)
        #expect(u.unpriced == 1)
        let opusInput: Double = 10 * 4.0
        let opusWrite: Double = 1000 * 8.0
        let opusOutput: Double = 100 * 20.0
        let opusRead: Double = 50_000 * 0.20
        let haikuOutput: Double = 1000 * 0.50
        let expected = (opusInput + opusWrite + opusOutput + opusRead + haikuOutput) / 1_000_000
        #expect(abs(u.cost - expected) < 1e-9)
    }

    @Test func cacheWritesWithoutABreakdownCountAsFiveMinute() {
        var meter = UsageMeter(since: start)
        meter.ingest(#"{"type":"assistant","timestamp":"2026-11-12T07:00:01.000Z","message":{"id":"x","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000000}}}"#)
        #expect(meter.usage.write5m == 1_000_000)
        #expect(abs(meter.usage.cost - 5) < 0.0001)
    }

    @Test func contextIsTheLatestMainPromptNotASubagents() {
        var meter = UsageMeter(since: start)
        meter.ingest(line(id: "a", ts: "2026-11-12T07:00:01.000Z", input: 5, write1h: 1000, read: 400_000))
        meter.ingest(line(id: "b", ts: "2026-11-12T07:00:02.000Z", input: 5, write1h: 2000, read: 401_000))
        meter.ingest(line(id: "c", ts: "2026-11-12T07:00:03.000Z", model: "claude-haiku-5-5", input: 5, read: 30_000), main: false)
        #expect(meter.usage.context == 5 + 2000 + 401_000)
        #expect(meter.usage.model == "claude-opus-5-5")
        #expect(ContextWindow.percent(meter.usage.context, of: 1_000_000) == 40)
    }

    @Test func contextWindowPrefersTheConfiguredOne() {
        #expect(ContextWindow.size(model: "claude-opus-5-5", configured: 400_000) == 400_000)
        #expect(ContextWindow.size(model: "claude-opus-5-5", configured: nil) == 1_000_000)
        #expect(ContextWindow.size(model: "claude-haiku-4-5", configured: nil) == 200_000)
        #expect(ContextWindow.size(model: nil, configured: 0) == 1_000_000)
    }

    @Test func rollingWindowCountsEachRequestOnceAndForgetsOldOnes() {
        var window = RollingWindow(length: 5 * 3600)
        let early = TranscriptLine.request(line(id: "e", ts: "2026-11-12T01:00:00.000Z", output: 1_000_000), notBefore: "")!
        let late = TranscriptLine.request(line(id: "l", ts: "2026-11-12T07:00:00.000Z", output: 100_000), notBefore: "")!
        window.add(early)
        window.add(late)
        window.add(late)
        #expect(window.calls(now: start) == 1)
        #expect(abs(window.cost(now: start) - 2) < 0.0001)
        #expect(abs(window.cost(now: start - 3 * 3600) - 22) < 0.0001)
        window.prune(now: start)
        #expect(window.calls(now: start - 3 * 3600) == 1)
    }

    @Test func requestKeepsTheExactTime() {
        let r = TranscriptLine.request(line(id: "x", ts: "2026-11-12T07:00:01.250Z", output: 1), notBefore: "2026-11-12T07:00:00.000Z")!
        #expect(abs(r.time - (start + 1.25)) < 0.001)
        #expect(TranscriptLine.request(line(id: "x", ts: "2026-11-12T06:59:59.000Z", output: 1), notBefore: "2026-11-12T07:00:00.000Z") == nil)
    }

    @Test func texts() {
        #expect(UsageText.cost(0.004) == "<$0.01")
        #expect(UsageText.cost(0.42) == "$0.42")
        #expect(UsageText.cost(3.14) == "$3.1")
        #expect(UsageText.cost(12.4) == "$12")
        #expect(UsageText.tokens(820) == "820")
        #expect(UsageText.tokens(45_400) == "45k")
        #expect(UsageText.tokens(3_420_000) == "3.4M")
        #expect(UsageText.duration(45) == "45s")
        #expect(UsageText.duration(12 * 60 + 5) == "12m")
        #expect(UsageText.duration(3600 + 5 * 60) == "1h 05m")
    }
}

@Suite struct Plan {
    let statusJSON = #"""
    {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":58,"resets_at":1794484200},"seven_day":{"used_percentage":16.4,"resets_at":1794999600}},
     "context_window":{"context_window_size":1000000,"used_percentage":5}}
    """#

    @Test func statusLineInputGivesTheRealLimitsAndContext() {
        let input = StatusLine.parse(Array(statusJSON.utf8), at: 1_794_470_000)
        #expect(input.limits?.fiveHour == PlanLimits.Window(percent: 58, resetsAt: 1_794_484_200))
        #expect(input.limits?.sevenDay?.percent == 16.4)
        #expect(input.contextPercent == 5)
        #expect(StatusLine.text(for: input, now: 1_794_470_000) == "5h 58% · 7d 16% · ctx 5%")
        // Past its reset the five-hour window no longer counts.
        #expect(StatusLine.text(for: input, now: 1_794_490_000) == "7d 16% · ctx 5%")
    }

    @Test func noRateLimitsMeansNoLimitsAtAll() {
        let input = StatusLine.parse(Array(#"{"context_window":{"used_percentage":12}}"#.utf8), at: 0)
        #expect(input.limits == nil)
        #expect(StatusLine.text(for: input, now: 0) == "ctx 12%")
        #expect(StatusLine.parse(Array("garbage".utf8), at: 0) == StatusLine.Input())
    }

    @Test func limitsRoundTrip() {
        let limits = PlanLimits(fiveHour: .init(percent: 58, resetsAt: 10), sevenDay: nil, updatedAt: 5)
        #expect(PlanLimits.decode(limits.encoded()) == limits)
    }

    @Test func turnShareIsCalibratedOnTheRealPercentage() {
        // 58% of the five hours for $116 of API-priced work: half a percent per dollar.
        let perDollar = LimitShare.perDollar(percent: 58, windowCost: 116)!
        #expect(abs(perDollar - 0.5) < 1e-9)
        #expect(LimitShare.text(LimitShare.percent(cost: 6, perDollar: perDollar)) == "3%")
        #expect(LimitShare.text(LimitShare.percent(cost: 0.5, perDollar: perDollar)) == "<1%")
        #expect(LimitShare.perDollar(percent: 1, windowCost: 50) == nil)
        #expect(LimitShare.perDollar(percent: 40, windowCost: 0.5) == nil)
    }

    @Test func limitIsCarriedForwardBetweenReports() {
        let limits = PlanLimits(fiveHour: .init(percent: 60, resetsAt: 10_000), sevenDay: nil, updatedAt: 1_000)
        // Fresh report: as it is.
        let fresh = LimitEstimate.fiveHour(limits, now: 1_050, costSinceReport: 0, perDollar: 0.5, nextWindow: nil)
        #expect(fresh == LimitEstimate(percent: 60, resetsAt: 10_000, exact: true))
        // Ten dollars of work later, at half a percent per dollar.
        let later = LimitEstimate.fiveHour(limits, now: 5_000, costSinceReport: 10, perDollar: 0.5, nextWindow: nil)
        #expect(later == LimitEstimate(percent: 65, resetsAt: 10_000, exact: false))
        // Never past 100.
        let capped = LimitEstimate.fiveHour(limits, now: 5_000, costSinceReport: 1_000, perDollar: 0.5, nextWindow: nil)
        #expect(capped?.percent == 100)
        // After the reset the next window begins with its first request.
        let next = LimitEstimate.fiveHour(limits, now: 12_000, costSinceReport: 0, perDollar: 0.5, nextWindow: (start: 11_000, cost: 8))
        #expect(next == LimitEstimate(percent: 4, resetsAt: 11_000 + PlanLimits.fiveHours, exact: false))
        // Nothing since the reset: no window yet.
        #expect(LimitEstimate.fiveHour(limits, now: 12_000, costSinceReport: 0, perDollar: 0.5, nextWindow: nil) == nil)
    }

    @Test func windowCostSinceThePlansWindowStarted() {
        var window = RollingWindow(length: 5 * 3600)
        let a = TranscriptLine.request(Substring(#"{"type":"assistant","timestamp":"2026-11-12T06:00:00.000Z","message":{"id":"a","model":"claude-opus-5-5","usage":{"output_tokens":1000000}}}"#), notBefore: "")!
        let b = TranscriptLine.request(Substring(#"{"type":"assistant","timestamp":"2026-11-12T08:00:00.000Z","message":{"id":"b","model":"claude-opus-5-5","usage":{"output_tokens":100000}}}"#), notBefore: "")!
        window.add(a)
        window.add(b)
        #expect(abs(window.cost(since: 1_794_466_800) - 2) < 0.0001)
    }
}

@Suite struct Reminders {
    func record(_ id: String, _ status: SessionStatus, since: Double) -> SessionRecord {
        SessionRecord(id: id, status: status, cwd: "/p", at: since)
    }

    @Test func remindsWaitingAndUnseenResultsOnceAfterTheDelay() {
        let records = [
            record("waiting", .waiting, since: 1000),
            record("unseen", .done, since: 1100),
            record("seen", .done, since: 1000),
            record("working", .working, since: 1000),
            record("tooSoon", .waiting, since: 1500),
        ]
        let due = SessionBoard.dueReminders(in: records, seen: ["seen": 1000], reminded: [:], now: 1700, after: 600, launch: 0)
        #expect(due.map(\.id) == ["waiting", "unseen"])
        let again = SessionBoard.dueReminders(in: records, seen: ["seen": 1000], reminded: ["waiting": 1000, "unseen": 1100], now: 1700, after: 600, launch: 0)
        #expect(again.isEmpty)
    }

    @Test func nothingDueBeforeLaunchAndNothingWhenOff() {
        let records = [record("old", .waiting, since: 1000)]
        #expect(SessionBoard.dueReminders(in: records, seen: [:], reminded: [:], now: 5000, after: 600, launch: 2000).isEmpty)
        #expect(SessionBoard.dueReminders(in: records, seen: [:], reminded: [:], now: 5000, after: 0, launch: 0).isEmpty)
    }

    @Test func turnTimeRunsWhileWorkingAndStopsAtTheEnd() {
        var r = record("s", .working, since: 100)
        #expect(SessionBoard.turnSeconds(of: r, now: 500) == nil)
        r.turnStartedAt = 100
        #expect(SessionBoard.turnSeconds(of: r, now: 500) == 400)
        r.status = .done
        r.statusSince = 460
        #expect(SessionBoard.turnSeconds(of: r, now: 900) == 360)
        r.status = .idle
        #expect(SessionBoard.turnSeconds(of: r, now: 900) == nil)
    }

    @Test func promptStartsTheTurnClock() {
        let e = HookEvent.parse(Array(#"{"session_id":"s1","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"go"}"#.utf8))!
        guard case .write(let r) = SessionRecord.apply(e, to: nil, at: 42) else {
            Issue.record("expected a write")
            return
        }
        #expect(r.turnStartedAt == 42)
    }
}
