import AppKit
import NordvaNotchCore

let arguments = CommandLine.arguments

if arguments.contains("--check") {
    exit(SelfCheck.run())
}

// --demo banner|list|compact|timer shows fake sessions, for screenshots.
let demo = arguments.firstIndex(of: "--demo").map { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : "banner" }

if demo == nil, let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    print("NordvaNotch is already running")
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(demo: demo)
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
