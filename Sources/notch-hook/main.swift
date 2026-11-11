import Foundation
import NordvaNotchCore

// Claude Code runs this for every hook event NordvaNotch listens to. It has to stay quick and
// quiet: no output, no network, and always exit 0 so it can never change what Claude does.
let now = Date().timeIntervalSince1970
let input = FileHandle.standardInput.readDataToEndOfFile()
if let event = HookEvent.parse([UInt8](input), environment: ProcessInfo.processInfo.environment) {
    let directory = ProcessInfo.processInfo.environment["NORDVA_NOTCH_DIR"] ?? SessionStore.defaultDirectory
    SessionStore(directory: directory).handle(event, at: now)
}
exit(0)
