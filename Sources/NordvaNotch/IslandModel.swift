import Foundation
import NordvaNotchCore

struct SessionRow: Identifiable, Equatable {
    var id: String
    var title: String
    var project: String
    var status: SessionStatus
    var statusText: String
    var reply: String?
    var since: Date
    var unseen: Bool
    var stalled: Bool
    var usage: TurnUsage?
    var record: SessionRecord
}

enum Banner: Equatable {
    case session(SessionRow)
    /// The same session again: still waiting, or finished and still unseen.
    case reminder(SessionRow)
    /// A turn that went past the cost limit in Settings.
    case heavy(SessionRow)
    case timer(minutes: Int)

    var row: SessionRow? {
        switch self {
        case .session(let row), .reminder(let row), .heavy(let row): return row
        case .timer: return nil
        }
    }

    func replacing(_ row: SessionRow) -> Banner {
        switch self {
        case .session: return .session(row)
        case .reminder: return .reminder(row)
        case .heavy: return .heavy(row)
        case .timer: return self
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
    @Published var showReply = true
    @Published var hovering = false
    /// The pill under the pointer while the peek strip is out.
    @Published var peekHover: Int?
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

    var timerRunning: Bool { timerEnd != nil }
}

/// What the view can ask the controller to do.
struct IslandActions {
    var openList: () -> Void = {}
    var open: (SessionRow) -> Void = { _ in }
    var startTimer: (Int) -> Void = { _ in }
    var addMinute: () -> Void = {}
    var stopTimer: () -> Void = {}
    var dismissBanner: () -> Void = {}
    var openSettings: () -> Void = {}
}
