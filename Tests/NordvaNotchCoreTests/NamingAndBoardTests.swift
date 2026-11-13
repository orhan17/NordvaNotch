import Testing
@testable import NordvaNotchCore

@Suite struct Naming {
    @Test func projectNameUsesTheRepoForClaudeWorktrees() {
        let home = "/Users/o"
        #expect(SessionNaming.projectName(cwd: "/Users/o/BackendProjects/testing/.claude/worktrees/quiet-otter-4f2a1c", home: home) == "testing")
        #expect(SessionNaming.projectName(cwd: "/Users/o/BackendProjects/testing/.claude/worktrees/x/sub", home: home) == "testing")
        #expect(SessionNaming.projectName(cwd: "/Users/o/BackendProjects/NordvaNotch/", home: home) == "NordvaNotch")
        #expect(SessionNaming.projectName(cwd: "/Users/o", home: home) == "~")
        #expect(SessionNaming.projectName(cwd: "", home: home) == "Unknown")
        #expect(SessionNaming.projectName(cwd: "/", home: home) == "/")
    }

    @Test func customTitleTakesTheLastOneInTheTail() {
        let tail = """
        {"type":"custom-title","customTitle":"Old name","sessionId":"s"}
        {"type":"user","message":{"content":"the word \\"custom-title\\" in a message"}}
        {"type":"custom-title","customTitle":"Остров в вырезе","sessionId":"s"}
        {"type":"assistant","message":{}}
        {"type":"custom-ti
        """
        #expect(SessionNaming.customTitle(inTranscriptTail: tail) == "Остров в вырезе")
        #expect(SessionNaming.customTitle(inTranscriptTail: #"{"type":"user"}"#) == nil)
    }

    @Test func displayTitleFallsBackFromTitleToPromptToFolder() {
        var r = SessionRecord(id: "s", status: .done, cwd: "/Users/o/p/NordvaNotch", at: 0)
        #expect(SessionNaming.displayTitle(of: r, transcriptTitle: nil, home: "/Users/o") == "NordvaNotch")
        r.prompt = "Build the notch app"
        #expect(SessionNaming.displayTitle(of: r, transcriptTitle: nil, home: "/Users/o") == "Build the notch app")
        #expect(SessionNaming.displayTitle(of: r, transcriptTitle: "Notch", home: "/Users/o") == "Notch")
        r.title = "From the hook"
        #expect(SessionNaming.displayTitle(of: r, transcriptTitle: "Notch", home: "/Users/o") == "From the hook")
    }

    @Test func timeTexts() {
        #expect(TimeText.ago(3) == "now")
        #expect(TimeText.ago(42) == "42s")
        #expect(TimeText.ago(5 * 60 + 59) == "5m")
        #expect(TimeText.ago(3 * 3600) == "3h")
        #expect(TimeText.ago(2 * 86400 + 5) == "2d")
        #expect(TimeText.countdown(245) == "4:05")
        #expect(TimeText.countdown(0.2) == "0:01")
        #expect(TimeText.countdown(0) == "0:00")
        #expect(TimeText.countdown(3723) == "1:02:03")
    }
}

@Suite struct Board {
    func record(_ id: String, _ status: SessionStatus, since: Double, updated: Double? = nil) -> SessionRecord {
        var r = SessionRecord(id: id, status: status, cwd: "/p", at: since)
        r.updatedAt = updated ?? since
        return r
    }

    @Test func ordersNeedsYouThenUnseenThenWorking() {
        let records = [
            record("idle", .idle, since: 50),
            record("seenDone", .done, since: 90),
            record("working", .working, since: 80),
            record("newDone", .done, since: 70),
            record("waiting", .waiting, since: 60),
        ]
        let ids = SessionBoard.ordered(records, seen: ["seenDone": 90], now: 100).map(\.id)
        #expect(ids == ["waiting", "newDone", "working", "seenDone", "idle"])
    }

    @Test func hidesOldSessionsUnlessTheyStillNeedYou() {
        let now = 100_000.0
        let records = [
            record("old", .done, since: 1, updated: 1),
            record("oldWaiting", .waiting, since: 1, updated: 1),
            record("fresh", .working, since: now - 10),
        ]
        let ids = SessionBoard.ordered(records, seen: ["old": 1], now: now).map(\.id)
        #expect(ids == ["oldWaiting", "fresh"])
    }

    @Test func alertsOncePerStatusAndNotForThingsBeforeLaunch() {
        let records = [
            record("a", .done, since: 200),
            record("b", .waiting, since: 150),
            record("c", .working, since: 210),
            record("d", .done, since: 90),
        ]
        let first = SessionBoard.newAlerts(in: records, announced: [:], launch: 100).map(\.id)
        #expect(first == ["b", "a"])
        let again = SessionBoard.newAlerts(in: records, announced: ["a": 200, "b": 150], launch: 100)
        #expect(again.isEmpty)
    }

    @Test func unseenAndStalled() {
        let done = record("a", .done, since: 200)
        #expect(SessionBoard.isUnseen(done, seen: [:]))
        #expect(!SessionBoard.isUnseen(done, seen: ["a": 200]))
        #expect(SessionBoard.unseenCount([done, record("b", .working, since: 1)], seen: [:]) == 1)
        let working = record("w", .working, since: 0, updated: 0)
        #expect(SessionBoard.isStalled(working, now: SessionBoard.stalledAfter + 1))
        #expect(!SessionBoard.isStalled(working, now: 60))
    }
}

@Suite struct Geometry {
    // MacBook Pro 14": 1512x982 points, notch between x 663.5 and 848.5, 32 pt tall.
    let builtIn = ScreenShape(
        frame: Rect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 32,
        auxiliaryTopLeft: Rect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: Rect(x: 848.5, y: 950, width: 663.5, height: 32),
        menuBarHeight: 32
    )
    let dell = ScreenShape(
        frame: Rect(x: 1512, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 0
    )

    @Test func anchorsToTheNotch() {
        let a = NotchAnchor(screen: builtIn)
        #expect(a.hasNotch)
        #expect(a.notchWidth == 185)
        #expect(a.centerX == 756)
        #expect(a.top == 982)
        #expect(a.height == 32)
        #expect(IslandLayout.frame(of: .idle, anchor: a) == Rect(x: 663.5, y: 950, width: 185, height: 32))
    }

    @Test func notchPositionDoesNotDependOnWhereTheAuxiliaryAreasAreMeasuredFrom() {
        // The built-in display to the left of a main external one, auxiliary areas in local coordinates.
        let left = ScreenShape(
            frame: Rect(x: -1512, y: 98, width: 1512, height: 982),
            safeAreaTop: 32,
            auxiliaryTopLeft: Rect(x: 0, y: 950, width: 663.5, height: 32),
            auxiliaryTopRight: Rect(x: 848.5, y: 950, width: 663.5, height: 32),
            menuBarHeight: 0
        )
        let a = NotchAnchor(screen: left)
        #expect(a.centerX == -1512 + 756)
        #expect(a.notchWidth == 185)
        #expect(a.top == 1080)
    }

    @Test func screenWithoutANotchGetsAPillInTheMiddle() {
        let a = NotchAnchor(screen: dell)
        #expect(!a.hasNotch)
        #expect(a.centerX == 1512 + 960)
        #expect(a.top == 1080)
        #expect(a.height == NotchAnchor.fallbackHeight)
        var withMenuBar = dell
        withMenuBar.menuBarHeight = 25
        #expect(NotchAnchor(screen: withMenuBar).height == 25)
    }

    @Test func shapesGrowDownFromTheTopEdge() {
        let a = NotchAnchor(screen: builtIn)
        let compact = IslandLayout.frame(of: .compact(timer: false), anchor: a)
        #expect(compact.width == 185 + IslandLayout.wing * 2)
        #expect(compact.maxY == 982)
        let timer = IslandLayout.frame(of: .compact(timer: true), anchor: a)
        #expect(timer.width == 185 + IslandLayout.timerWing * 2)
        #expect(timer.midX == 756)
        let banner = IslandLayout.frame(of: .banner(lines: 0), anchor: a)
        #expect(banner.midX == 756)
        #expect(banner.maxY == 982)
        #expect(banner.height == 32 + IslandLayout.bannerBody)
        let finished = IslandLayout.frame(of: .banner(lines: 3), anchor: a)
        #expect(finished.width == IslandLayout.bannerWideWidth)
        #expect(finished.height == banner.height + IslandLayout.bannerLinesGap + 3 * IslandLayout.bannerLine)
        #expect(finished.maxY == 982)
        let one = IslandLayout.size(of: .list(rows: 0, timer: true), anchor: a)
        let six = IslandLayout.size(of: .list(rows: 6, timer: true), anchor: a)
        let twenty = IslandLayout.size(of: .list(rows: 20, timer: true), anchor: a)
        let noTimer = IslandLayout.size(of: .list(rows: 6, timer: false), anchor: a)
        #expect(six.height - noTimer.height == IslandLayout.listFooter + IslandLayout.listPadding - IslandLayout.listEnd)
        #expect(noTimer.width == six.width)
        #expect(six.height - one.height == 5 * IslandLayout.rowHeight)
        #expect(twenty == six)
        #expect(six.height <= IslandLayout.canvasHeight)
    }

    @Test func peekStripHangsFromTheNotchWithEqualPills() {
        let a = NotchAnchor(screen: builtIn)
        let strip = IslandLayout.frame(of: .peek(pills: 3), anchor: a)
        #expect(strip.width == IslandLayout.peekWidth)
        #expect(strip.height == 32 + IslandLayout.peekBody)
        #expect(strip.maxY == 982)
        #expect(IslandLayout.pillWidth(count: 1, anchor: a) == IslandLayout.maxPillWidth)
        let three = IslandLayout.pillWidth(count: 3, anchor: a)
        #expect(three * 3 + IslandLayout.pillSpacing * 2 == IslandLayout.peekWidth - IslandLayout.peekPadding * 2)
        #expect(three > 140)
    }

    @Test func pillUnderThePointer() {
        let a = NotchAnchor(screen: builtIn)
        let y = 982 - 32 - IslandLayout.pillTop - IslandLayout.pillHeight / 2
        let pill = IslandLayout.pillWidth(count: 2, anchor: a)
        // Two pills centred on x 756: [756 - pill - 3, 756 - 3) and [756 + 3, 756 + pill + 3).
        #expect(IslandLayout.pillIndex(x: 756 - pill, y: y, count: 2, anchor: a) == 0)
        #expect(IslandLayout.pillIndex(x: 756 + 4, y: y, count: 2, anchor: a) == 1)
        #expect(IslandLayout.pillIndex(x: 756, y: y, count: 2, anchor: a) == nil)
        #expect(IslandLayout.pillIndex(x: 756 + pill + 10, y: y, count: 2, anchor: a) == nil)
        #expect(IslandLayout.pillIndex(x: 756 + 4, y: 970, count: 2, anchor: a) == nil)
        #expect(IslandLayout.pillIndex(x: 756, y: y, count: 0, anchor: a) == nil)
    }

    @Test func panelHugsTheShapeWithAMargin() {
        let a = NotchAnchor(screen: builtIn)
        let idle = IslandLayout.panelFrame(for: .idle, anchor: a)
        #expect(idle.maxY == 982)
        #expect(idle.midX == 756)
        #expect(idle.width == 185 + IslandLayout.panelMargin * 2)
        #expect(idle.height == 32 + IslandLayout.panelMargin)
        let list = IslandLayout.panelFrame(for: .list(rows: 6, timer: false), anchor: a)
        #expect(list.height > idle.height)
        #expect(list.maxY == 982)
    }

    @Test func idleNotchIsClickableButAnIdlePillIsNot() {
        let notch = NotchAnchor(screen: builtIn)
        #expect(IslandLayout.isInteractive(mode: .idle, anchor: notch, x: 756, y: 970))
        #expect(!IslandLayout.isInteractive(mode: .idle, anchor: notch, x: 600, y: 970))
        let pill = NotchAnchor(screen: dell)
        #expect(!IslandLayout.isInteractive(mode: .idle, anchor: pill, x: 2472, y: 1070))
        #expect(IslandLayout.isInteractive(mode: .compact(timer: false), anchor: pill, x: 2472, y: 1070))
    }
}

@Suite struct Links {
    @Test func desktopSessionsOpenByTheirLocalID() {
        var r = SessionRecord(id: "s", status: .done, cwd: "/p", at: 0)
        #expect(SessionLink.desktopURL(for: r) == nil)
        r.entrypoint = "claude-desktop"
        r.hostSessionID = "local_3c9e8a71-2b4d-4e6f-9a1c-5d7e0f2b8c46"
        #expect(SessionLink.desktopURL(for: r) == "claude://code/continue?session=local_3c9e8a71-2b4d-4e6f-9a1c-5d7e0f2b8c46")
        r.hostSessionID = "local_x&prompt=hi"
        #expect(SessionLink.desktopURL(for: r) == nil)
        r.hostSessionID = "local_3c9e8a71"
        r.entrypoint = "cli"
        #expect(SessionLink.desktopURL(for: r) == nil)
    }

    @Test func shortCountdownFitsTheWing() {
        #expect(TimeText.shortCountdown(59 * 60 + 59) == "59:59")
        #expect(TimeText.shortCountdown(3600 + 2 * 60) == "1h02")
    }
}
