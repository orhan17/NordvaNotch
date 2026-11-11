import AppKit
import NordvaNotchCore

/// `--check`: prints what the app sees, without any UI.
enum SelfCheck {
    static func run() -> Int32 {
        for screen in NSScreen.screens {
            let anchor = NotchAnchor(screen: screen.shape)
            let kind = anchor.hasNotch ? "notch \(Int(anchor.notchWidth))x\(Int(anchor.height))" : "no notch, pill \(Int(anchor.height)) pt"
            print("screen \(screen.localizedName): \(Int(screen.frame.width))x\(Int(screen.frame.height)), \(kind), centre x \(anchor.centerX)")
        }

        let helper = HookStatus.helperPath
        print("hook helper: \(helper) \(FileManager.default.isExecutableFile(atPath: helper) ? "ok" : "MISSING")")
        print("hooks in ~/.claude/settings.json: \(HookStatus.isInstalled ? "connected" : "not connected")")

        let store = SessionStore(directory: SessionStore.defaultDirectory)
        let now = Date().timeIntervalSince1970
        let records = SessionBoard.ordered(store.all(), seen: Preferences().seen, now: now)
        print("sessions: \(records.count)")
        for record in records {
            let title = SessionNaming.displayTitle(of: record, transcriptTitle: nil, home: NSHomeDirectory())
            let project = SessionNaming.projectName(cwd: record.cwd, home: NSHomeDirectory())
            let via = record.entrypoint ?? "?"
            print("  [\(record.status.rawValue)] \(title) - \(project), \(SessionNaming.statusText(of: record)), \(TimeText.ago(now - record.statusSince)) ago, via \(via)")
        }
        return FileManager.default.isExecutableFile(atPath: helper) ? 0 : 1
    }
}
