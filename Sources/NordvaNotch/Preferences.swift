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
