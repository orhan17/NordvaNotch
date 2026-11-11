import AppKit

/// Trackpad clicks and sounds. A haptic is only felt while a finger rests on the trackpad;
/// the API gives no way to know, so a sound is the fallback for things that must not be missed.
final class Feedback {
    private let prefs: Preferences
    /// For off-screen rendering: no clicks, no sounds.
    var muted = false

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    /// The faintest click, for the peek strip.
    func tick() {
        guard !muted, prefs.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func alert(taps: Int, sound: String?) {
        guard !muted else { return }
        if prefs.haptics {
            for index in 0..<max(1, taps) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 * Double(index)) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
        if let sound { NSSound(named: NSSound.Name(sound))?.play() }
    }
}
