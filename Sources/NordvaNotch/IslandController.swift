import AppKit
import NordvaNotchCore
import SwiftUI

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, below menus that open from it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Borderless windows are still pushed below the menu bar unless this is overridden.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class IslandHostingView: NSHostingView<IslandView> {
    var contextMenu: (() -> NSMenu)?

    // The app is never active, so without this the first click would only focus the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

extension NSRect {
    var rect: Rect { Rect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}

extension Rect {
    var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

extension NSScreen {
    var shape: ScreenShape {
        ScreenShape(
            frame: frame.rect,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea?.rect,
            auxiliaryTopRight: auxiliaryTopRightArea?.rect,
            menuBarHeight: max(0, frame.maxY - visibleFrame.maxY)
        )
    }
}

/// Owns the panel and decides what the island shows.
final class IslandController {
    let model = IslandModel()
    var openSettings: () -> Void = {}
    var contextMenu: (() -> NSMenu)?

    private let prefs: Preferences
    private let feedback: Feedback
    private let panel = IslandPanel()
    private var records: [SessionRecord] = []
    private var titles: [String: String] = [:]
    private var announced: [String: Double] = [:]
    private var seen: [String: Double]
    private let launch = Date().timeIntervalSince1970
    private var listOpen = false
    private var peekOpen = false
    private var hoverWork: DispatchWorkItem?
    private var peekCollapseWork: DispatchWorkItem?
    /// Something was held back during a call; keep the dot even if the compact wings are off.
    private var quietPending = false
    private var bannerWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var homeWork: DispatchWorkItem?
    private var countdown: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Off for demos and pictures, so a made-up timer never lands in the real defaults.
    var persistsTimer = true

    init(prefs: Preferences, feedback: Feedback) {
        self.prefs = prefs
        self.feedback = feedback
        seen = prefs.seen
        model.showReply = prefs.showReply
    }

    func start() {
        let host = IslandHostingView(rootView: IslandView(model: model, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: IslandLayout.canvasWidth, height: IslandLayout.canvasHeight)
        host.contextMenu = { [weak self] in self?.contextMenu?() ?? NSMenu() }
        panel.contentView = host
        if let screen = homeScreen() { place(on: screen) }
        applyPreferences()
        panel.orderFrontRegardless()

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.pointerMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.clickedElsewhere()
        }) {
            monitors.append(m)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.goHome() })
        restoreTimer()
    }

    func applyPreferences() {
        model.showReply = prefs.showReply
        model.timerEnabled = prefs.timerEnabled
        model.showWorking = prefs.showWorking
        if !prefs.timerEnabled {
            if model.timerRunning { stopTimer() }
            model.timerDone = false
        }
        // Screenshots, recordings and screen sharing leave out windows with sharingType .none.
        panel.sharingType = prefs.hideFromScreenSharing ? .none : .readOnly
        refreshMode()
    }

    /// During a call nothing expands or clicks on its own; a dot waits instead.
    private func shouldStayQuiet() -> Bool {
        prefs.quietDuringCalls && CallMonitor.current().inCall
    }

    private var actions: IslandActions {
        IslandActions(
            openList: { [weak self] in self?.openList() },
            open: { [weak self] row in self?.open(row) },
            startTimer: { [weak self] minutes in self?.startTimer(minutes: minutes) },
            addMinute: { [weak self] in self?.addMinute() },
            stopTimer: { [weak self] in self?.stopTimer() },
            dismissBanner: { [weak self] in self?.dismissBanner() },
            openSettings: { [weak self] in
                self?.closeList()
                self?.openSettings()
            }
        )
    }

    // MARK: Sessions

    func update(records: [SessionRecord], titles: [String: String]) {
        self.records = records
        self.titles = titles
        let alerts = SessionBoard.newAlerts(in: records, announced: announced, launch: launch)
        for alert in alerts { announced[alert.id] = alert.statusSince }
        refreshRows()

        let wanted = alerts.filter { $0.status == .waiting ? prefs.popOnWaiting : prefs.popOnDone }
        if let latest = wanted.last {
            if shouldStayQuiet() {
                quietPending = true
            } else {
                let urgent = wanted.contains { $0.status == .waiting }
                feedback.alert(taps: urgent ? 2 : 1, sound: prefs.sessionSound ? "Tink" : nil)
                show(.session(row(for: latest)))
            }
        }
        refreshMode()
    }

    var sessionRows: [SessionRow] { model.rows }

    private func row(for record: SessionRecord) -> SessionRow {
        let now = Date().timeIntervalSince1970
        return SessionRow(
            id: record.id,
            title: SessionNaming.displayTitle(of: record, transcriptTitle: titles[record.id], home: NSHomeDirectory()),
            project: SessionNaming.projectName(cwd: record.cwd, home: NSHomeDirectory()),
            status: record.status,
            statusText: SessionNaming.statusText(of: record),
            reply: record.reply,
            since: Date(timeIntervalSince1970: record.statusSince),
            unseen: SessionBoard.isUnseen(record, seen: seen),
            stalled: SessionBoard.isStalled(record, now: now),
            record: record
        )
    }

    private func refreshRows() {
        let now = Date().timeIntervalSince1970
        let ordered = SessionBoard.ordered(records, seen: seen, now: now)
        let rows = ordered.prefix(IslandLayout.maxVisibleRows).map(row(for:))
        if model.rows != rows { model.rows = rows }
        model.hiddenCount = max(0, ordered.count - rows.count)
        model.workingCount = records.filter { $0.status == .working && !SessionBoard.isStalled($0, now: now) }.count
        model.unseenCount = SessionBoard.unseenCount(records, seen: seen)
        model.attention = ordered.first { SessionBoard.isUnseen($0, seen: seen) }?.status
        if case .session(let shown) = model.banner, let fresh = records.first(where: { $0.id == shown.id }) {
            let updated = Banner.session(row(for: fresh))
            if model.banner != updated { model.banner = updated }
        }
    }

    func markSeen(_ ids: [String]) {
        for id in ids {
            if let record = records.first(where: { $0.id == id }) { seen[id] = record.statusSince }
        }
        let live = Set(records.map(\.id))
        seen = seen.filter { live.contains($0.key) }
        prefs.seen = seen
        refreshRows()
        refreshMode()
    }

    func open(_ row: SessionRow) {
        markSeen([row.id])
        let record = row.record
        if let link = SessionLink.desktopURL(for: record), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        } else if let bundle = record.hostBundleID {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if listOpen {
            closeList()
        } else if peekOpen {
            closePeek()
        } else {
            dismissBanner()
        }
    }

    // MARK: Modes

    func openList() {
        bannerWork?.cancel()
        hoverWork?.cancel()
        hoverWork = nil
        peekOpen = false
        model.peekHover = nil
        model.banner = nil
        quietPending = false
        model.timerDone = false
        listOpen = true
        refreshMode()
        // Opened from the menu bar with the pointer far away: close on its own after a while.
        if !model.hovering { scheduleCollapse(after: 6) }
    }

    func closeList() {
        guard listOpen else { return }
        collapseWork?.cancel()
        listOpen = false
        markSeen(model.rows.map(\.id))
        refreshMode()
    }

    private func show(_ banner: Banner) {
        guard !listOpen else { return }
        peekOpen = false
        model.peekHover = nil
        if prefs.placement == .pointer, let screen = pointerScreen() { place(on: screen) }
        model.banner = banner
        refreshMode()
        if case .timer = banner {
            scheduleBannerHide(after: 20)
        } else {
            scheduleBannerHide(after: prefs.bannerSeconds)
        }
    }

    private func scheduleBannerHide(after seconds: Double) {
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.model.hovering {
                self.scheduleBannerHide(after: 1.5)
                return
            }
            self.dismissBanner()
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func dismissBanner() {
        bannerWork?.cancel()
        guard model.banner != nil else { return }
        model.banner = nil
        refreshMode()
    }

    private func refreshMode() {
        let mode: IslandMode
        if listOpen {
            mode = .list(rows: model.rows.count, timer: prefs.timerEnabled)
        } else if model.banner != nil {
            mode = .banner
        } else if peekOpen {
            mode = .peek(pills: min(model.rows.count, IslandLayout.maxPills))
        } else if compactWanted {
            mode = .compact(timer: model.timerRunning)
        } else {
            mode = .idle
        }
        if model.mode != mode { model.mode = mode }
        if !listOpen && model.banner == nil && !peekOpen { scheduleGoHome() }
        pointerMoved()
    }

    private var compactWanted: Bool {
        let showAttention = prefs.compactIndicators || quietPending
        if model.showAttention != showAttention { model.showAttention = showAttention }
        let attention = showAttention && (model.unseenCount > 0 || model.timerRunning || model.timerDone)
        let working = prefs.showWorking && model.workingCount > 0
        return attention || working
    }

    // MARK: Pointer

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let inside = IslandLayout.isInteractive(mode: model.mode, anchor: model.anchor, x: p.x, y: p.y)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        trackPeek(inside: inside, at: p)
        guard model.hovering != inside else { return }
        model.hovering = inside
        if listOpen {
            if inside { collapseWork?.cancel() } else { scheduleCollapse(after: 0.7) }
        }
    }

    /// Resting on the notch slides out the peek strip; a pointer that only passes it on the
    /// way to the menu bar spends far less than the delay inside and never triggers it.
    private func trackPeek(inside: Bool, at p: NSPoint) {
        if peekOpen {
            if persistsPeek { return }
            let count = min(model.rows.count, IslandLayout.maxPills)
            let hover = inside ? IslandLayout.pillIndex(x: p.x, y: p.y, count: count, anchor: model.anchor) : nil
            if model.peekHover != hover { model.peekHover = hover }
            if inside {
                peekCollapseWork?.cancel()
                peekCollapseWork = nil
            } else if peekCollapseWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.closePeek() }
                peekCollapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
            return
        }
        var resting = model.mode == .idle
        if case .compact = model.mode { resting = true }
        guard inside, resting, !listOpen, model.banner == nil, !model.rows.isEmpty else {
            hoverWork?.cancel()
            hoverWork = nil
            return
        }
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            let q = NSEvent.mouseLocation
            guard !self.listOpen, self.model.banner == nil,
                  IslandLayout.isInteractive(mode: self.model.mode, anchor: self.model.anchor, x: q.x, y: q.y)
            else { return }
            self.openPeek()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: work)
    }

    static let peekDelay = 0.3
    /// Demo only: keep the strip out whatever the pointer does.
    private var persistsPeek = false

    private func openPeek() {
        peekOpen = true
        peekCollapseWork = nil
        if !shouldStayQuiet() { feedback.tick() }
        refreshMode()
    }

    private func closePeek() {
        guard peekOpen, !persistsPeek else { return }
        peekCollapseWork?.cancel()
        peekCollapseWork = nil
        peekOpen = false
        model.peekHover = nil
        refreshMode()
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeList() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clickedElsewhere() {
        if listOpen { closeList() }
        closePeek()
    }

    // MARK: Screens

    private func homeScreen() -> NSScreen? {
        NSScreen.screens.first { $0.shape.hasNotch } ?? NSScreen.screens.first
    }

    private func pointerScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? homeScreen()
    }

    private func place(on screen: NSScreen) {
        homeWork?.cancel()
        let anchor = NotchAnchor(screen: screen.shape)
        if model.anchor != anchor {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.anchor = anchor }
        }
        let frame = IslandLayout.canvas(anchor: anchor).nsRect
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// After a banner on another display, return to the notch once the shape has collapsed.
    private func scheduleGoHome() {
        homeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.goHome() }
        homeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func goHome() {
        guard !listOpen, model.banner == nil, let screen = homeScreen() else { return }
        place(on: screen)
    }

    // MARK: Timer

    func startTimer(minutes: Int) {
        model.timerMinutes = minutes
        model.timerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        model.timerDone = false
        if case .timer = model.banner { model.banner = nil }
        scheduleCountdown()
        refreshMode()
    }

    func addMinute() {
        guard let end = model.timerEnd else { return }
        model.timerEnd = end.addingTimeInterval(60)
        scheduleCountdown()
    }

    func stopTimer() {
        countdown?.invalidate()
        model.timerEnd = nil
        saveTimer()
        refreshMode()
    }

    /// A running timer survives a restart of the app, an update included.
    private func saveTimer() {
        guard persistsTimer else { return }
        let defaults = UserDefaults.standard
        if let end = model.timerEnd {
            defaults.set(end.timeIntervalSince1970, forKey: "timerEnd")
            defaults.set(model.timerMinutes, forKey: "timerMinutes")
        } else {
            defaults.removeObject(forKey: "timerEnd")
            defaults.removeObject(forKey: "timerMinutes")
        }
    }

    private func restoreTimer() {
        guard persistsTimer, prefs.timerEnabled else { return }
        let defaults = UserDefaults.standard
        let end = defaults.double(forKey: "timerEnd")
        guard end > Date().timeIntervalSince1970 else {
            defaults.removeObject(forKey: "timerEnd")
            return
        }
        model.timerMinutes = defaults.integer(forKey: "timerMinutes")
        model.timerEnd = Date(timeIntervalSince1970: end)
        scheduleCountdown()
        refreshMode()
    }

    var timerEnd: Date? { model.timerEnd }

    private func scheduleCountdown() {
        countdown?.invalidate()
        saveTimer()
        guard let end = model.timerEnd else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.timerFinished() }
        RunLoop.main.add(timer, forMode: .common)
        countdown = timer
    }

    private func timerFinished() {
        model.timerEnd = nil
        saveTimer()
        if shouldStayQuiet() {
            quietPending = true
            model.timerDone = true
            refreshMode()
            return
        }
        feedback.alert(taps: 2, sound: prefs.timerSound ? "Glass" : nil)
        if listOpen {
            collapseWork?.cancel()
            listOpen = false
        }
        show(.timer(minutes: model.timerMinutes))
    }

    /// Settings → Preview: one made-up banner. Leaves the real sessions and seen marks alone.
    func preview() {
        var record = SessionRecord(id: "preview", status: .done, cwd: NSHomeDirectory() + "/Projects/NordvaNotch", at: Date().timeIntervalSince1970)
        record.title = "Notch island"
        record.reply = "Done. Tests pass and the new build is installed."
        feedback.alert(taps: 1, sound: prefs.sessionSound ? "Tink" : nil)
        show(.session(row(for: record)))
    }

    // MARK: Demo

    /// Shows fake sessions without touching the real ones; used for screenshots.
    func demo(_ mode: String) {
        persistsTimer = false
        let now = Date().timeIntervalSince1970 + 1
        func fake(_ id: String, _ status: SessionStatus, _ title: String, _ cwd: String, ago: Double, reply: String? = nil, wait: WaitReason? = nil, detail: String? = nil) -> SessionRecord {
            var r = SessionRecord(id: id, status: status, cwd: cwd, at: now - ago)
            r.title = title
            r.reply = reply
            r.waitReason = wait
            r.detail = detail
            return r
        }
        let home = NSHomeDirectory()
        let list = [
            fake("d1", .working, "Booking API: pagination", "\(home)/BackendProjects/booking", ago: 40),
            fake("d2", .waiting, "Fix flaky crawler test", "\(home)/BackendProjects/seo-crawler", ago: 120, wait: .permission, detail: "Bash"),
            fake("d3", .idle, "RAG service: reranker", "\(home)/BackendProjects/go-rag", ago: 3600),
        ]
        switch mode {
        case "list":
            update(records: list, titles: [:])
            openList()
            collapseWork?.cancel()
        case "peek", "peek-hover":
            update(records: list + [fake("d4", .done, "Notch island", "\(home)/BackendProjects/NordvaNotch", ago: 300,
                                         reply: "Done. Tests pass and the new build is installed.")], titles: [:])
            dismissBanner()
            openPeek()
            peekCollapseWork?.cancel()
            persistsPeek = true
            if mode == "peek-hover" { model.peekHover = 1 }
        case "compact":
            update(records: list + [fake("d4", .done, "Notch island", "\(home)/BackendProjects/NordvaNotch", ago: 5)], titles: [:])
            dismissBanner()
        case "timer":
            startTimer(minutes: 25)
        default:
            update(records: list + [fake(
                "d4", .done, "Notch island", "\(home)/BackendProjects/NordvaNotch", ago: -2,
                reply: "Done. Tests pass and the new build is installed."
            )], titles: [:])
        }
    }
}
