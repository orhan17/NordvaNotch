import Testing
@testable import NordvaNotchCore

@Suite struct Store {
    @Test func handlesEventsEndToEnd() {
        let store = SessionStore(directory: "/tmp/nordva-notch-tests-\(Int.random(in: 0..<1_000_000_000))")
        let sid = "7b0c3a52-0000-4000-8000-000000000001"
        let prompt = HookEvent.parse(Array(#"{"session_id":"\#(sid)","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8))!
        let stop = HookEvent.parse(Array(#"{"session_id":"\#(sid)","hook_event_name":"Stop","last_assistant_message":"hello"}"#.utf8))!
        let end = HookEvent.parse(Array(#"{"session_id":"\#(sid)","hook_event_name":"SessionEnd"}"#.utf8))!

        store.handle(prompt, at: 10)
        #expect(store.record(id: sid)?.status == .working)
        store.handle(stop, at: 20)
        #expect(store.record(id: sid)?.reply == "hello")
        #expect(store.all().map(\.id) == [sid])

        store.prune(now: 20 + SessionBoard.pruneAfter - 1)
        #expect(store.all().count == 1)
        store.handle(end, at: 30)
        #expect(store.all().isEmpty)

        store.handle(prompt, at: 40)
        store.prune(now: 40 + SessionBoard.pruneAfter + 1)
        #expect(store.all().isEmpty)
    }
}

@Suite struct Setup {
    @Test func commandSurvivesAMissingAppAndOddPaths() {
        #expect(HookSetup.command(helperPath: "/Applications/NordvaNotch.app/Contents/MacOS/notch-hook")
            == "/Applications/NordvaNotch.app/Contents/MacOS/notch-hook || true")
        #expect(HookSetup.command(helperPath: "/Users/o/My Apps/N.app/Contents/MacOS/notch-hook")
            == "'/Users/o/My Apps/N.app/Contents/MacOS/notch-hook' || true")
    }

    @Test func snippetListsEveryEventOnce() {
        let text = HookSetup.snippet(helperPath: "/Applications/NordvaNotch.app/Contents/MacOS/notch-hook")
        for entry in HookSetup.entries {
            #expect(text.contains("\"\(entry.event)\": ["))
        }
        #expect(text.contains("\"matcher\": \"AskUserQuestion|ExitPlanMode\""))
        #expect(text.contains("\"async\": true"))
        #expect(HookSetup.isInstalled(settingsText: text))
        #expect(!HookSetup.isInstalled(settingsText: #"{"hooks":{}}"#))
    }
}
