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

        let call = CallMonitor.current()
        print("camera in use: \(call.camera), microphone in use: \(call.microphone)")

        let helper = HookStatus.helperPath
        print("hook helper: \(helper) \(FileManager.default.isExecutableFile(atPath: helper) ? "ok" : "MISSING")")
        print("hooks in ~/.claude/settings.json: \(HookStatus.isInstalled ? "connected" : "not connected")")

        let store = SessionStore(directory: ProcessInfo.processInfo.environment["NORDVA_NOTCH_DIR"] ?? SessionStore.defaultDirectory)
        let now = Date().timeIntervalSince1970
        let records = SessionBoard.ordered(store.all(), seen: Preferences().seen, now: now)
        print("sessions: \(records.count)")
        let snapshot = UsageTracker().refresh(records: records, now: now)
        let usage = snapshot.turns
        print("last 5 hours, every session and agent: \(snapshot.windowCalls) calls, ≈ \(UsageText.cost(snapshot.windowCost)) at API prices")
        let window = snapshot.configuredContext.map { "autoCompactWindow \($0)" } ?? "model default"
        print("context measured against: \(window)")
        if let limits = snapshot.limits {
            let age = TimeText.ago(now - limits.updatedAt)
            for (name, value) in [("5h", limits.fiveHour), ("7d", limits.sevenDay)] {
                guard let value else { continue }
                let state = value.resetsAt > now ? "resets \(TurnText.clock(value.resetsAt))" : "already reset"
                print("plan limit \(name): \(Int(value.percent.rounded()))%, \(state)")
            }
            print("plan limits reported \(age == "now" ? "just now" : age + " ago") by \(limits.source ?? "?")")
            if let rate = snapshot.perDollar {
                print(String(format: "rate from the report: about %.2f%% of 5h per dollar at API prices", rate))
            }
            if let five = snapshot.fiveHour {
                print(String(format: "five-hour limit now: %@%.0f%%, resets %@", five.exact ? "" : "≈", five.percent, TurnText.clock(five.resetsAt)))
            }
        } else {
            print("plan limits: none yet (status line not connected, or API billing)")
        }
        for record in records {
            let title = SessionNaming.displayTitle(of: record, transcriptTitle: nil, home: NSHomeDirectory())
            let project = SessionNaming.projectName(cwd: record.cwd, home: NSHomeDirectory())
            let via = record.entrypoint ?? "?"
            print("  [\(record.status.rawValue)] \(title) - \(project), \(SessionNaming.statusText(of: record)), \(agoText(now - record.statusSince)), via \(via)")
            if let seconds = SessionBoard.turnSeconds(of: record, now: now) {
                var line = "    turn \(UsageText.duration(seconds))"
                if let u = usage[record.id] {
                    line += ", \(u.calls) calls, \(UsageText.tokens(u.tokens)) tokens"
                    line += " (in \(u.input), out \(u.output), write \(u.write5m + u.write1h), read \(u.read))"
                    line += ", ≈ \(UsageText.cost(u.cost)) at API prices, \(u.agents) agents"
                    let size = ContextWindow.size(model: u.model, configured: snapshot.configuredContext)
                    line += ", context \(ContextWindow.percent(u.context, of: size))% (\(UsageText.tokens(u.context)))"
                }
                print(line)
            }
        }
        return FileManager.default.isExecutableFile(atPath: helper) ? 0 : 1
    }

    private static func agoText(_ seconds: Double) -> String {
        let ago = TimeText.ago(seconds)
        return ago == "now" ? "just now" : ago + " ago"
    }
}
