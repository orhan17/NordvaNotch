import Testing
@testable import NordvaNotchCore

@Suite("Session text")
struct SessionTextTests {
    @Test func promptLosesSystemRemindersAndPasteMarkers() {
        #expect(SessionText.prompt("<system-reminder>\nLinked sessions now</system-reminder>\nship it") == "ship it")
        #expect(SessionText.prompt("<system-reminder> cut off before the end") == nil)
        #expect(SessionText.prompt("write a letter <pasted_content id=\"21b0\">Senior PHP\nremote</pasted_content>") == "write a letter Senior PHP remote")
        #expect(SessionText.prompt("<task-notification>\n<task-id>b1</task-id>") == nil)
        #expect(SessionText.prompt("  fix   the\nbuild ") == "fix the build")
    }

    @Test func replyBecomesPlainLines() {
        let markdown = """
        ## Done

        **Fonts:** bigger, see [the README](https://example.com/readme).

        - one
        * two
        ---
        ```swift
        let hidden = true
        ```
        | File | Lines |
        |------|------:|
        | `a.swift` | 12 |
        > quoted
        """
        #expect(SessionText.reply(markdown, limit: 600) == "Done\nFonts: bigger, see the README.\n• one\n• two\nFile · Lines\na.swift · 12\nquoted")
        #expect(SessionText.reply("```\nonly code\n```", limit: 600) == nil)
        #expect(SessionText.reply("abcdefghij\nklm", limit: 8) == "abcdefg…")
        #expect(SessionText.oneLine("a\nb") == "a b")
    }
}
