import Foundation
import NordvaNotchCore

// Claude Code runs this for every hook event NordvaNotch listens to. It has to stay quick and
// quiet: no output, no network, and always exit 0 so it can never change what Claude does.
let now = Date().timeIntervalSince1970
let input = FileHandle.standardInput.readDataToEndOfFile()

// As a status line command: keep the plan limits for the app and print one line for the terminal.
if CommandLine.arguments.contains("--statusline") {
    let status = StatusLine.parse([UInt8](input), at: now)
    if var limits = status.limits {
        limits.source = ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"]
        let path = ProcessInfo.processInfo.environment["NORDVA_NOTCH_LIMITS"] ?? PlanLimits.defaultPath
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temp = folder + "/.limits.\(getpid()).tmp"
        if FileManager.default.createFile(atPath: temp, contents: Data(limits.encoded())), rename(temp, path) != 0 {
            unlink(temp)
        }
    }
    print(StatusLine.text(for: status, now: now))
    exit(0)
}

if let event = HookEvent.parse([UInt8](input), environment: ProcessInfo.processInfo.environment) {
    let directory = ProcessInfo.processInfo.environment["NORDVA_NOTCH_DIR"] ?? SessionStore.defaultDirectory
    SessionStore(directory: directory).handle(event, at: now)
}
exit(0)
