import Foundation
import NordvaNotchCore

struct SessionRow: Identifiable, Equatable {
    var id: String
    var title: String
    var project: String
    var status: SessionStatus
    var statusText: String
    /// The reply as plain lines, and the prompt that started the turn.
    var reply: String?
    var prompt: String?
    var since: Date
    var unseen: Bool
    var stalled: Bool
    var usage: TurnUsage?
    /// How full the session's context is, against `autoCompactWindow` or the model's window.
    var contextPercent: Int?
    /// The turn's usage in short ("≈3%" of the plan's five hours, or "≈ $0.42" on API billing) and long form.
    var costShort: String?
    var costLong: String?
    var record: SessionRecord
}

enum Banner: Equatable {
    case session(SessionRow)
    /// The same session again: still waiting, or finished and still unseen.
    case reminder(SessionRow)
    /// A turn that went past the cost limit in Settings.
    case heavy(SessionRow)
    /// The last five hours went past the limit in Settings, all sessions together:
    /// the plan's percentage, or the cost at API prices without a plan.
    case window(cost: Double)
    case planLimit(LimitEstimate, week: PlanLimits.Window?)
    /// A busy five-hour window has reset: carry on.
    case limitReset(peak: Double, week: PlanLimits.Window?)
    /// A session whose context is nearly full: compaction is near.
    case context(SessionRow)
    case timer(minutes: Int)

    var row: SessionRow? {
        switch self {
        case .session(let row), .reminder(let row), .heavy(let row), .context(let row): return row
        case .timer, .window, .planLimit, .limitReset: return nil
        }
    }

    func replacing(_ row: SessionRow) -> Banner {
        switch self {
        case .session: return .session(row)
        case .reminder: return .reminder(row)
        case .heavy: return .heavy(row)
        case .context: return .context(row)
        case .timer, .window, .planLimit, .limitReset: return self
        }
    }
}

/// Everything the SwiftUI view draws. The controller owns the logic and writes here.
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .idle
    @Published var anchor = NotchAnchor(centerX: 0, top: 0, notchWidth: 180, height: 32, hasNotch: true)
    @Published var rows: [SessionRow] = []
    @Published var hiddenCount = 0
    @Published var workingCount = 0
    @Published var unseenCount = 0
    /// The most urgent unseen status, for the dot in the compact wing.
    @Published var attention: SessionStatus?
    @Published var banner: Banner?
    @Published var bannerDetail = Preferences.BannerDetail.full
    @Published var hovering = false
    /// The pill under the pointer while the peek strip is out.
    @Published var peekHover: Int?
    /// The row picked with the arrow keys when the list is open from the keyboard.
    @Published var selectedRow: Int?
    @Published var timerEnd: Date?
    @Published var timerMinutes = 0
    /// A spinner and a count next to the notch while sessions work.
    @Published var showWorking = true
    /// Dots for unseen results; off in Settings, but forced on after a call held something back.
    @Published var showAttention = true
    /// The timer is optional and off by default: the island is about Claude Code first.
    @Published var timerEnabled = false
    /// A timer ended while the island had to stay quiet; cleared once the list is opened.
    @Published var timerDone = false
    /// Every session and agent over the last five hours, at API prices; nil before the first reading.
    @Published var windowCost: Double?
    /// The plan's limits, when Claude Code reports them (Pro and Max): the five hours carried forward
    /// from the last report, the week as reported.
    @Published var fiveHour: LimitEstimate?
    @Published var sevenDay: PlanLimits.Window?
    @Published var contextWarnPercent = 85

    var timerRunning: Bool { timerEnd != nil }
}

/// What the view can ask the controller to do.
struct IslandActions {
    var openList: () -> Void = {}
    var open: (SessionRow) -> Void = { _ in }
    var remove: (SessionRow) -> Void = { _ in }
    var startTimer: (Int) -> Void = { _ in }
    var addMinute: () -> Void = {}
    var stopTimer: () -> Void = {}
    var dismissBanner: () -> Void = {}
    var openSettings: () -> Void = {}
}
