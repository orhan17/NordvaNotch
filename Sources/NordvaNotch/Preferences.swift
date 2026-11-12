import Foundation

final class Preferences: ObservableObject {
    enum Placement: String, CaseIterable, Identifiable {
        case notch
        case pointer

        var id: String { rawValue }
        var title: String {
            switch self {
            case .notch: return "Built-in display notch"
            case .pointer: return "Display with the pointer"
            }
        }
    }

    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    @Published var placement: Placement { didSet { save(placement.rawValue, "placement") } }
    @Published var popOnDone: Bool { didSet { save(popOnDone, "popOnDone") } }
    @Published var popOnWaiting: Bool { didSet { save(popOnWaiting, "popOnWaiting") } }
    @Published var showReply: Bool { didSet { save(showReply, "showReply") } }
    @Published var bannerSeconds: Double { didSet { save(bannerSeconds, "bannerSeconds") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var sessionSound: Bool { didSet { save(sessionSound, "sessionSound") } }
    @Published var timerSound: Bool { didSet { save(timerSound, "timerSound") } }
    @Published var compactIndicators: Bool { didSet { save(compactIndicators, "compactIndicators") } }
    @Published var menuBarIcon: Bool { didSet { save(menuBarIcon, "menuBarIcon") } }
    @Published var hideFromScreenSharing: Bool { didSet { save(hideFromScreenSharing, "hideFromScreenSharing") } }
    @Published var quietDuringCalls: Bool { didSet { save(quietDuringCalls, "quietDuringCalls") } }
    @Published var timerEnabled: Bool { didSet { save(timerEnabled, "timerEnabled") } }
    @Published var showWorking: Bool { didSet { save(showWorking, "showWorking") } }
    /// Minutes before a waiting session or an unseen result is announced again; 0 is off.
    @Published var remindMinutes: Int { didSet { save(remindMinutes, "remindMinutes") } }
    /// Dollars at API prices that make a turn worth a warning; 0 is off.
    @Published var heavyTurnDollars: Int { didSet { save(heavyTurnDollars, "heavyTurnDollars") } }
    /// Dollars at API prices over five hours, all sessions together, that deserve a warning; 0 is off.
    @Published var windowDollars: Int { didSet { save(windowDollars, "windowDollars") } }
    /// On a plan: the five-hour limit's percentage that deserves a warning; 0 is off.
    @Published var limitWarnPercent: Int { didSet { save(limitWarnPercent, "limitWarnPercent") } }
    /// On a plan: one turn's share of the five-hour limit that deserves a warning; 0 is off.
    @Published var heavyTurnPercent: Int { didSet { save(heavyTurnPercent, "heavyTurnPercent") } }
    /// Say when a five-hour window that got past 70% resets.
    @Published var resetNotice: Bool { didSet { save(resetNotice, "resetNotice") } }
    @Published var shortcut: HotKey.Shortcut { didSet { save(shortcut.rawValue, "shortcut") } }
    /// Context fill, in percent, that deserves a warning; 0 is off.
    @Published var contextWarnPercent: Int { didSet { save(contextWarnPercent, "contextWarnPercent") } }

    init() {
        defaults.register(defaults: [
            "placement": Placement.notch.rawValue,
            "popOnDone": true,
            "popOnWaiting": true,
            "showReply": true,
            "bannerSeconds": 6.0,
            "haptics": true,
            "sessionSound": false,
            "timerSound": true,
            "compactIndicators": true,
            "menuBarIcon": true,
            "hideFromScreenSharing": true,
            "quietDuringCalls": true,
            "timerEnabled": false,
            "showWorking": true,
            "remindMinutes": 10,
            "heavyTurnDollars": 10,
            "windowDollars": 150,
            "limitWarnPercent": 80,
            "heavyTurnPercent": 10,
            "resetNotice": true,
            "shortcut": HotKey.Shortcut.optionCommandL.rawValue,
            "contextWarnPercent": 85,
        ])
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .notch
        popOnDone = defaults.bool(forKey: "popOnDone")
        popOnWaiting = defaults.bool(forKey: "popOnWaiting")
        showReply = defaults.bool(forKey: "showReply")
        bannerSeconds = defaults.double(forKey: "bannerSeconds")
        haptics = defaults.bool(forKey: "haptics")
        sessionSound = defaults.bool(forKey: "sessionSound")
        timerSound = defaults.bool(forKey: "timerSound")
        compactIndicators = defaults.bool(forKey: "compactIndicators")
        menuBarIcon = defaults.bool(forKey: "menuBarIcon")
        hideFromScreenSharing = defaults.bool(forKey: "hideFromScreenSharing")
        quietDuringCalls = defaults.bool(forKey: "quietDuringCalls")
        timerEnabled = defaults.bool(forKey: "timerEnabled")
        showWorking = defaults.bool(forKey: "showWorking")
        remindMinutes = defaults.integer(forKey: "remindMinutes")
        heavyTurnDollars = defaults.integer(forKey: "heavyTurnDollars")
        windowDollars = defaults.integer(forKey: "windowDollars")
        limitWarnPercent = defaults.integer(forKey: "limitWarnPercent")
        heavyTurnPercent = defaults.integer(forKey: "heavyTurnPercent")
        resetNotice = defaults.bool(forKey: "resetNotice")
        shortcut = HotKey.Shortcut(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .optionCommandL
        contextWarnPercent = defaults.integer(forKey: "contextWarnPercent")
    }

    /// Seen marks survive restarts, otherwise every finished session would light up again.
    var seen: [String: Double] {
        get { defaults.dictionary(forKey: "seen") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "seen") }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
