import AppKit
import NordvaNotchCore
import ServiceManagement
import SwiftUI

enum HookStatus {
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(HookSetup.helperName)").path
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return HookSetup.isInstalled(settingsText: text)
    }
}

final class SettingsWindowController {
    private let prefs: Preferences
    private let preview: () -> Void
    private var window: NSWindow?

    init(prefs: Preferences, preview: @escaping () -> Void) {
        self.prefs = prefs
        self.preview = preview
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: prefs, preview: preview))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = "NordvaNotch Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        if let window, !window.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2 + 80))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let preview: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var hooksInstalled = HookStatus.isInstalled
    @State private var copied = false
    /// Claude Code has reported plan limits through the status line at least once.
    private var onPlan: Bool { FileManager.default.fileExists(atPath: PlanLimits.defaultPath) }

    private var bannerDetailNote: String {
        switch prefs.bannerDetail {
        case .full: return "The banner grows: time, limit and context, your prompt and up to four lines of the reply."
        case .line: return "One line: the project, time and the start of the reply."
        case .none: return "The project and time only."
        }
    }

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Hooks") {
                    Label(
                        hooksInstalled ? "Connected" : "Not connected, see the README",
                        systemImage: hooksInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(hooksInstalled ? Color.green : Color.orange)
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Hook Settings") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HookSetup.snippet(helperPath: HookStatus.helperPath), forType: .string)
                        copied = true
                    }
                    Button("Show settings.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([HookStatus.settingsURL])
                    }
                    Spacer()
                    Button("Preview") { preview() }
                }
                Toggle("Expand when a session finishes", isOn: $prefs.popOnDone)
                Toggle("Expand when a session needs you", isOn: $prefs.popOnWaiting)
                Picker("A finished turn shows", selection: $prefs.bannerDetail) {
                    ForEach(Preferences.BannerDetail.allCases) { Text($0.title).tag($0) }
                }
                Text(bannerDetailNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Remind again after", selection: $prefs.remindMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Text("Once more, for a session that still waits for you or a result you have not opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if onPlan {
                    Picker("Warn at the five-hour limit", selection: $prefs.limitWarnPercent) {
                        Text("Off").tag(0)
                        ForEach([70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Toggle("Tell me when a busy five hours reset", isOn: $prefs.resetNotice)
                    Picker("Warn when one turn uses", selection: $prefs.heavyTurnPercent) {
                        Text("Off").tag(0)
                        ForEach([5, 10, 20, 30], id: \.self) { Text("\($0)% of 5h").tag($0) }
                    }
                    Text("The five-hour and weekly limits come from Claude Code's status line. A turn's share is an estimate: the window's real percentage spread over its requests by API price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                Picker("Warn when a turn costs over", selection: $prefs.heavyTurnDollars) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 20, 50], id: \.self) { Text("$\($0)").tag($0) }
                }
                Picker("Warn when 5 hours cost over", selection: $prefs.windowDollars) {
                    Text("Off").tag(0)
                    ForEach([50, 100, 150, 200, 300], id: \.self) { Text("$\($0)").tag($0) }
                }
                Text("At Anthropic API prices from the session transcripts, subagents included; the five hours add up every session. On a Pro or Max plan, connect the status line (see the README) to see the plan's real limits instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Picker("Warn when context is", selection: $prefs.contextWarnPercent) {
                    Text("Off").tag(0)
                    ForEach([70, 80, 85, 90], id: \.self) { Text("\($0)% full").tag($0) }
                }
            }

            Section("Island") {
                Picker("Show events on", selection: $prefs.placement) {
                    ForEach(Preferences.Placement.allCases) { Text($0.title).tag($0) }
                }
                Text("Without a notch (lid closed, or only an external display) the island hangs from the middle of the top edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Keep an event open") {
                    Stepper("\(Int(prefs.bannerSeconds)) s", value: $prefs.bannerSeconds, in: 3...20, step: 1)
                }
                Picker("Open the list with", selection: $prefs.shortcut) {
                    ForEach(HotKey.Shortcut.allCases) { Text($0.title).tag($0) }
                }
                Text("Arrows pick a session, Return opens it, Delete removes it from the notch, Escape closes the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Spinner next to the notch while sessions work", isOn: $prefs.showWorking)
                Toggle("Dot and count next to the notch until you look", isOn: $prefs.compactIndicators)
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $prefs.hideFromScreenSharing)
                Text("Screenshots, screen recordings and shared screens leave the island out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Quiet during calls", isOn: $prefs.quietDuringCalls)
                Text("While a camera or microphone is in use, the island shows a dot instead of expanding and does not click the trackpad. Click it to see what happened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    LabeledContent("Right now") { Text(callText(CallMonitor.current())).foregroundStyle(.secondary) }
                }
            }

            Section("Feedback") {
                Toggle("Haptic click on the trackpad", isOn: $prefs.haptics)
                Toggle("Sound for sessions", isOn: $prefs.sessionSound)
            }

            Section("Timer") {
                Toggle("Timer", isOn: $prefs.timerEnabled)
                Text("5 to 45 minute countdowns from the session list and the menu bar. Off keeps the island about Claude Code only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Sound when a timer ends", isOn: $prefs.timerSound)
                    .disabled(!prefs.timerEnabled)
            }

            Section("General") {
                Toggle("Menu bar icon", isOn: $prefs.menuBarIcon)
                Text("Without it, right-click the notch for the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hooksInstalled = HookStatus.isInstalled
            copied = false
        }
    }

    private func callText(_ state: CallMonitor.State) -> String {
        switch (state.camera, state.microphone) {
        case (true, true): return "Camera and microphone in use"
        case (true, false): return "Camera in use"
        case (false, true): return "Microphone in use"
        case (false, false): return "No call"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
