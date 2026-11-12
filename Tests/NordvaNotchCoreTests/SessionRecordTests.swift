import Testing
@testable import NordvaNotchCore

private func event(_ json: String, env: [String: String] = [:]) -> HookEvent {
    HookEvent.parse(Array(json.utf8), environment: env)!
}

private func written(_ update: SessionRecord.Update) -> SessionRecord {
    guard case .write(let record) = update else {
        Issue.record("expected a write, got \(update)")
        return SessionRecord(id: "x", status: .idle, cwd: "", at: 0)
    }
    return record
}

private let sid = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b"

@Suite struct HookEventParsing {
    @Test func readsCommonFieldsAndEnvironment() {
        let e = event(
            """
            {"session_id":"\(sid)","transcript_path":"/t.jsonl","cwd":"/Users/o/p","hook_event_name":"UserPromptSubmit",
             "prompt":"Fix the build","session_title":"Build fix","permission_mode":"default"}
            """,
            env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_HOST_SESSION_ID": "local_abc", "__CFBundleIdentifier": ""]
        )
        #expect(e.kind == .userPromptSubmit)
        #expect(e.sessionID == sid)
        #expect(e.cwd == "/Users/o/p")
        #expect(e.transcriptPath == "/t.jsonl")
        #expect(e.prompt == "Fix the build")
        #expect(e.sessionTitle == "Build fix")
        #expect(e.entrypoint == "claude-desktop")
        #expect(e.hostSessionID == "local_abc")
        #expect(e.hostBundleID == nil)
    }

    @Test func ignoresUnknownEventsAndBrokenInput() {
        #expect(HookEvent.parse(Array(#"{"session_id":"a","hook_event_name":"PreCompact"}"#.utf8)) == nil)
        #expect(HookEvent.parse(Array("not json".utf8)) == nil)
        #expect(HookEvent.parse(Array(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
    }

    @Test func rejectsIDsThatCouldEscapeTheFolder() {
        #expect(HookEvent.parse(Array(#"{"session_id":"../../x","hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(!HookEvent.isSafeID("a/b"))
        #expect(!HookEvent.isSafeID(""))
        #expect(HookEvent.isSafeID(sid))
    }
}

@Suite struct StatusMachine {
    func start(at time: Double = 100) -> SessionRecord {
        let e = event(#"{"session_id":"\#(sid)","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"Go"}"#)
        return written(SessionRecord.apply(e, to: nil, at: time))
    }

    @Test func promptStartsWork() {
        let r = start()
        #expect(r.status == .working)
        #expect(r.prompt == "Go")
        #expect(r.statusSince == 100)
        #expect(r.createdAt == 100)
    }

    @Test func stopFinishesAndKeepsTheReply() {
        let stop = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop","last_assistant_message":"All tests pass.\n\nDone."}"#)
        let r = written(SessionRecord.apply(stop, to: start(), at: 130))
        #expect(r.status == .done)
        #expect(r.reply == "All tests pass. Done.")
        #expect(r.statusSince == 130)
        #expect(r.cwd == "/p")
    }

    @Test func permissionRequestWaitsAndToolResultResumes() {
        let ask = event(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#)
        let waiting = written(SessionRecord.apply(ask, to: start(), at: 110))
        #expect(waiting.status == .waiting)
        #expect(waiting.waitReason == .permission)
        #expect(waiting.detail == "Bash")
        #expect(SessionNaming.statusText(of: waiting) == "Needs permission: Bash")

        let ran = event(#"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
        let resumed = written(SessionRecord.apply(ran, to: waiting, at: 120))
        #expect(resumed.status == .working)
        #expect(resumed.waitReason == nil)
        #expect(resumed.statusSince == 120)
    }

    @Test func permissionNotificationDoesNotOverrideAKnownWait() {
        let ask = event(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"Edit"}"#)
        let waiting = written(SessionRecord.apply(ask, to: start(), at: 110))
        let note = event(#"{"session_id":"\#(sid)","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Edit"}"#)
        #expect(SessionRecord.apply(note, to: waiting, at: 116) == .ignore)
        let alone = written(SessionRecord.apply(note, to: start(), at: 116))
        #expect(alone.waitReason == .permission)
        #expect(alone.detail == "Claude needs your permission to use Edit")
    }

    @Test func desktopQuestionStaysAQuestionThroughItsPermissionRequest() {
        // Seen live in the desktop app: PreToolUse(AskUserQuestion), then PermissionRequest for the same tool.
        let pre = event(#"{"session_id":"\#(sid)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#)
        let asked = written(SessionRecord.apply(pre, to: start(), at: 110))
        let permission = event(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion"}"#)
        let after = written(SessionRecord.apply(permission, to: asked, at: 110.05))
        #expect(after.waitReason == .question)
        #expect(after.statusSince == 110)
        #expect(SessionNaming.statusText(of: after) == "Asks you a question")
    }

    @Test func toolCallsWhileWorkingDoNotRewriteTheFile() {
        let ran = event(#"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","tool_name":"Read"}"#)
        #expect(SessionRecord.apply(ran, to: start(), at: 120) == .ignore)
        let beat = written(SessionRecord.apply(ran, to: start(), at: 100 + SessionRecord.heartbeat + 1))
        #expect(beat.status == .working)
        #expect(beat.statusSince == 100)
    }

    @Test func questionsAndPlansWaitForTheUser() {
        let question = event(#"{"session_id":"\#(sid)","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#)
        #expect(written(SessionRecord.apply(question, to: start(), at: 110)).waitReason == .question)
        let plan = event(#"{"session_id":"\#(sid)","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}"#)
        #expect(written(SessionRecord.apply(plan, to: start(), at: 110)).waitReason == .plan)
    }

    @Test func olderEventsCannotOverwriteNewerOnes() {
        let stop = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop"}"#)
        let done = written(SessionRecord.apply(stop, to: start(), at: 130))
        let late = event(#"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
        #expect(SessionRecord.apply(late, to: done, at: 129.9) == .ignore)
    }

    @Test func subagentToolCallsAreIgnoredButTheirPermissionRequestsAreNot() {
        let tool = event(#"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","agent_id":"a1","tool_name":"Bash"}"#)
        let stop = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop"}"#)
        let done = written(SessionRecord.apply(stop, to: start(), at: 130))
        #expect(SessionRecord.apply(tool, to: done, at: 140) == .ignore)

        let ask = event(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","agent_id":"a1","tool_name":"Bash"}"#)
        #expect(written(SessionRecord.apply(ask, to: done, at: 140)).status == .waiting)
    }

    @Test func idlePromptOnlyFinishesAStuckTurn() {
        let idle = event(#"{"session_id":"\#(sid)","hook_event_name":"Notification","notification_type":"idle_prompt"}"#)
        #expect(written(SessionRecord.apply(idle, to: start(), at: 200)).status == .done)
        let stop = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop"}"#)
        let done = written(SessionRecord.apply(stop, to: start(), at: 130))
        #expect(SessionRecord.apply(idle, to: done, at: 190) == .ignore)
    }

    @Test func scriptsAndSDKAppsAreIgnored() {
        let json = #"{"session_id":"\#(sid)","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#
        for entrypoint in ["sdk-cli", "sdk-ts", "sdk-py"] {
            #expect(SessionRecord.apply(event(json, env: ["CLAUDE_CODE_ENTRYPOINT": entrypoint]), to: nil, at: 100) == .ignore)
        }
        for entrypoint in ["cli", "claude-desktop", "claude-vscode"] {
            #expect(written(SessionRecord.apply(event(json, env: ["CLAUDE_CODE_ENTRYPOINT": entrypoint]), to: nil, at: 100)).status == .working)
        }
    }

    @Test func stopKeepsWhatIsStillRunningAndAPromptClearsIt() {
        let stop = event(#"""
        {"session_id":"\#(sid)","hook_event_name":"Stop","background_tasks":[
          {"id":"t1","type":"subagent","status":"running","description":"review","agent_type":"Explore"},
          {"id":"t2","type":"workflow","status":"running","description":"fan out","name":"wf"},
          {"id":"t3","type":"shell","status":"running","description":"build","command":"swift build"}],
         "session_crons":[]}
        """#)
        let done = written(SessionRecord.apply(stop, to: start(), at: 130))
        #expect(done.backgroundAgents == 2)
        #expect(done.backgroundCommands == 1)
        #expect(SessionNaming.statusText(of: done) == "Finished · 2 agents and 1 command still running")

        let back = event(#"{"session_id":"\#(sid)","hook_event_name":"UserPromptSubmit","prompt":"agent result"}"#)
        let working = written(SessionRecord.apply(back, to: done, at: 140))
        #expect(working.backgroundAgents == nil)

        let quiet = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop","background_tasks":[]}"#)
        #expect(SessionNaming.statusText(of: written(SessionRecord.apply(quiet, to: working, at: 150))) == "Finished")
        let older = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop"}"#)
        #expect(SessionNaming.statusText(of: written(SessionRecord.apply(older, to: working, at: 150))) == "Finished")
    }

    @Test func otherNotificationsAreIgnored() {
        let note = event(#"{"session_id":"\#(sid)","hook_event_name":"Notification","notification_type":"auth_success"}"#)
        #expect(SessionRecord.apply(note, to: start(), at: 110) == .ignore)
    }

    @Test func failureKeepsTheError() {
        let fail = event(#"{"session_id":"\#(sid)","hook_event_name":"StopFailure","error":"rate_limit"}"#)
        let r = written(SessionRecord.apply(fail, to: start(), at: 110))
        #expect(r.status == .failed)
        #expect(SessionNaming.statusText(of: r) == "Failed: rate_limit")
    }

    @Test func sessionEndRemovesTheRecord() {
        let end = event(#"{"session_id":"\#(sid)","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#)
        #expect(SessionRecord.apply(end, to: start(), at: 110) == .remove)
        #expect(SessionRecord.apply(end, to: nil, at: 110) == .ignore)
    }

    @Test func sessionStartCreatesAnIdleRecordAndKeepsAnExistingStatus() {
        let begin = event(#"{"session_id":"\#(sid)","cwd":"/p","hook_event_name":"SessionStart","source":"startup","session_title":"Notch"}"#)
        let fresh = written(SessionRecord.apply(begin, to: nil, at: 100))
        #expect(fresh.status == .idle)
        #expect(fresh.title == "Notch")
        #expect(written(SessionRecord.apply(begin, to: start(), at: 110)).status == .working)
    }

    @Test func newPromptClearsTheOldReply() {
        let stop = event(#"{"session_id":"\#(sid)","hook_event_name":"Stop","last_assistant_message":"Done"}"#)
        let done = written(SessionRecord.apply(stop, to: start(), at: 130))
        let again = event(#"{"session_id":"\#(sid)","hook_event_name":"UserPromptSubmit","prompt":"Next"}"#)
        let r = written(SessionRecord.apply(again, to: done, at: 140))
        #expect(r.reply == nil)
        #expect(r.prompt == "Next")
        #expect(r.createdAt == 100)
    }

    @Test func clipKeepsOneShortLine() {
        #expect(SessionRecord.clip("  a\n\n b\tc  ", to: 10) == "a b c")
        #expect(SessionRecord.clip("abcdefghijkl", to: 5) == "abcd…")
        #expect(SessionRecord.clip("Привет, мир", to: 7) == "Привет…")
    }

    @Test func recordRoundTripsThroughJSON() {
        var r = start()
        r.reply = "ok"
        r.hostSessionID = "local_1"
        #expect(SessionRecord.decode(r.encoded()) == r)
    }
}
