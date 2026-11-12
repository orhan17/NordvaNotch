import AppKit
import Carbon.HIToolbox
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

    /// Only while the list is open from the keyboard: arrows and Return then reach it,
    /// without activating the app or taking the focus away for longer.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
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
    private var host: IslandHostingView?
    private var records: [SessionRecord] = []
    private var titles: [String: String] = [:]
    private var announced: [String: Double] = [:]
    private var usage: [String: TurnUsage] = [:]
    private var snapshot = UsageSnapshot()
    /// Percent of the plan's five hours per dollar at API prices, from the last good reading.
    private var perDollar: Double?
    /// Armed again once the window falls back under 80% of the limit.
    private var windowWarned = false
    private var windowWarnedFor: Double?
    /// Armed again once the context falls 15 points under the limit, after a compaction.
    private var contextWarned: Set<String> = []
    /// statusSince of the status last reminded about, per session.
    private var reminded: [String: Double] = [:]
    /// turnStartedAt of the turn last warned about, per session.
    private var warnedHeavy: [String: Double] = [:]
    private var seen: [String: Double]
    private let launch = Date().timeIntervalSince1970
    private var listOpen = false
    /// The list was opened with the shortcut and takes arrows, Return and Escape.
    private var keyboardList = false
    /// The five-hour window being watched and the highest it got, to say when a busy one resets.
    private var watchedWindow: (resetsAt: Double, peak: Double)?
    private var resetToAnnounce: Double?
    private var peekOpen = false
    private var hoverWork: DispatchWorkItem?
    private var peekCollapseWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
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
        self.host = host
        host.contextMenu = { [weak self] in self?.contextMenu?() ?? NSMenu() }
        // The SwiftUI view keeps one fixed size; the window is only a frame around it that grows and
        // shrinks with the shape. Moving the view inside the window is AppKit's business and is never
        // animated, so the shape cannot drift while the window changes.
        let container = NSView()
        container.autoresizesSubviews = false
        container.addSubview(host)
        panel.contentView = container
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
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event) == true ? nil : event
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
        set(\.showReply, prefs.showReply)
        set(\.timerEnabled, prefs.timerEnabled)
        set(\.showWorking, prefs.showWorking)
        set(\.contextWarnPercent, prefs.contextWarnPercent)
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
            remove: { [weak self] row in self?.remove(row) },
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

    func update(records: [SessionRecord], titles: [String: String], usage: UsageSnapshot = UsageSnapshot()) {
        self.records = records
        self.titles = titles
        self.snapshot = usage
        self.usage = usage.turns
        set(\.windowCost, usage.windowCalls > 0 ? usage.windowCost : nil)
        let now = Date().timeIntervalSince1970
        set(\.fiveHour, usage.fiveHour)
        set(\.sevenDay, usage.limits?.active(usage.limits?.sevenDay, now: now))
        perDollar = usage.perDollar
        watchWindow(now: now)
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
        if model.banner == nil && !listOpen {
            _ = remindIfDue() || announceReset() || warnIfHeavy() || warnIfWindowHeavy() || warnIfContextFull()
        }
        refreshMode()
    }

    /// A session still waiting, or a result still unseen, after the delay in Settings: say it once more.
    @discardableResult
    private func remindIfDue() -> Bool {
        let due = SessionBoard.dueReminders(
            in: records, seen: seen, reminded: reminded, now: Date().timeIntervalSince1970,
            after: Double(prefs.remindMinutes) * 60, launch: launch
        )
        guard let latest = due.last else { return false }
        // During a call it waits: the dot is already there, and the reminder comes after the call.
        guard !shouldStayQuiet() else { return false }
        for record in due { reminded[record.id] = record.statusSince }
        feedback.alert(taps: 1, sound: prefs.sessionSound ? "Tink" : nil)
        show(.reminder(row(for: latest)))
        return true
    }

    /// A turn costing more than the limit in Settings, at API prices: warn once per turn.
    @discardableResult
    private func warnIfHeavy() -> Bool {
        // On a plan the limit is a share of the five hours; on API billing it is dollars.
        func weight(_ usage: TurnUsage) -> Double? {
            snapshot.limits != nil ? planShare(of: usage) : usage.cost
        }
        let limit = Double(snapshot.limits != nil ? prefs.heavyTurnPercent : prefs.heavyTurnDollars)
        guard limit > 0 else { return false }
        let heavy = records.filter { record in
            guard let start = record.turnStartedAt, let turn = usage[record.id], let value = weight(turn) else { return false }
            return value >= limit && warnedHeavy[record.id] != start
        }
        guard let worst = heavy.max(by: { (usage[$0.id].flatMap(weight) ?? 0) < (usage[$1.id].flatMap(weight) ?? 0) }) else { return false }
        guard !shouldStayQuiet() else { return false }
        for record in heavy { warnedHeavy[record.id] = record.turnStartedAt }
        feedback.alert(taps: 2, sound: nil)
        show(.heavy(row(for: worst)))
        return true
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
            usage: usage[record.id],
            contextPercent: contextPercent(of: record),
            costShort: costTexts(usage[record.id]).short,
            costLong: costTexts(usage[record.id]).long,
            record: record
        )
    }

    private func refreshRows() {
        let now = Date().timeIntervalSince1970
        let ordered = SessionBoard.ordered(records, seen: seen, now: now)
        // Six rows show at a time; more scroll. Fifty is plenty and keeps the list cheap.
        let rows = ordered.prefix(50).map(row(for:))
        // @Published announces every assignment, equal or not, and each one costs SwiftUI a full
        // layout pass; this runs every 15 seconds, so only real changes are written.
        set(\.rows, rows)
        set(\.hiddenCount, max(0, ordered.count - rows.count))
        // A finished turn whose agents still run is still work in progress; long-lived commands are not.
        set(\.workingCount, records.filter {
            ($0.status == .working && !SessionBoard.isStalled($0, now: now))
                || ($0.status == .done && ($0.backgroundAgents ?? 0) > 0 && now - $0.statusSince < SessionBoard.stalledAfter)
        }.count)
        set(\.unseenCount, SessionBoard.unseenCount(records, seen: seen))
        set(\.attention, ordered.first { SessionBoard.isUnseen($0, seen: seen) }?.status)
        if let banner = model.banner, let shown = banner.row, let fresh = records.first(where: { $0.id == shown.id }) {
            let updated = banner.replacing(row(for: fresh))
            if model.banner != updated { model.banner = updated }
        }
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<IslandModel, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
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

    /// The shortcut: opens the list for the keyboard, or closes it.
    func toggleListFromKeyboard() {
        if listOpen {
            closeList()
            return
        }
        openList()
        collapseWork?.cancel()
        keyboardList = true
        model.selectedRow = model.rows.isEmpty ? nil : 0
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
    }

    /// Arrows move, Return opens, Escape closes. Only while the list is open from the keyboard.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard listOpen, keyboardList else { return false }
        let count = model.rows.count
        switch Int(event.keyCode) {
        case kVK_Escape:
            closeList()
        case kVK_DownArrow where count > 0:
            model.selectedRow = min(count - 1, (model.selectedRow ?? -1) + 1)
        case kVK_UpArrow where count > 0:
            model.selectedRow = max(0, (model.selectedRow ?? count) - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let index = model.selectedRow, model.rows.indices.contains(index) { open(model.rows[index]) }
        case kVK_Delete, kVK_ForwardDelete:
            if let index = model.selectedRow, model.rows.indices.contains(index) { remove(model.rows[index]) }
        default:
            return false
        }
        return true
    }

    /// Deletes the session's record; the next hook event of that session brings it back.
    var removeSessions: ([String]) -> Void = { _ in }

    func remove(_ row: SessionRow) {
        removeSessions([row.id])
        records.removeAll { $0.id == row.id }
        seen[row.id] = nil
        prefs.seen = seen
        refreshRows()
        if let index = model.selectedRow {
            model.selectedRow = model.rows.isEmpty ? nil : min(index, model.rows.count - 1)
        }
        refreshMode()
    }

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
        if keyboardList {
            keyboardList = false
            model.selectedRow = nil
            panel.allowsKey = false
            panel.resignKey()
        }
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
        if model.mode != mode {
            fitPanel(to: mode)
            model.mode = mode
        }
        if !listOpen && model.banner == nil && !peekOpen { scheduleGoHome() }
        pointerMoved()
    }

    /// Grows the panel before the shape expands, so the animation is never clipped, and shrinks
    /// it once the shape has settled.
    private func fitPanel(to mode: IslandMode) {
        shrinkWork?.cancel()
        let target = IslandLayout.panelFrame(for: mode, anchor: model.anchor).nsRect
        let current = panel.frame
        if target.width > current.width || target.height > current.height {
            let width = max(target.width, current.width)
            let height = max(target.height, current.height)
            resizePanel(to: NSRect(x: target.midX - width / 2, y: target.maxY - height, width: width, height: height))
        }
        guard panel.frame != target else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == mode else { return }
            self.resizePanel(to: target)
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// The window's top centre is always the notch, and so is the SwiftUI view's.
    private func resizePanel(to frame: NSRect) {
        panel.setFrame(frame, display: false)
        host?.setFrameOrigin(NSPoint(
            x: (frame.width - IslandLayout.canvasWidth) / 2,
            y: frame.height - IslandLayout.canvasHeight
        ))
        panel.display()
    }

    private var compactWanted: Bool {
        let showAttention = prefs.compactIndicators || quietPending
        if model.showAttention != showAttention { model.showAttention = showAttention }
        let attention = showAttention && (model.unseenCount > 0 || model.timerRunning || model.timerDone)
        let working = prefs.showWorking && model.workingCount > 0
        return attention || working
    }

    /// When a five-hour window that got past 70% resets, the next message is the time to carry on.
    static let busyWindow = 70.0

    private func watchWindow(now: Double) {
        if let watched = watchedWindow, now >= watched.resetsAt {
            if watched.peak >= Self.busyWindow { resetToAnnounce = watched.peak }
            watchedWindow = nil
        }
        if let five = model.fiveHour, five.resetsAt > now {
            let peak = watchedWindow?.resetsAt == five.resetsAt ? max(watchedWindow?.peak ?? 0, five.percent) : five.percent
            watchedWindow = (five.resetsAt, peak)
        }
    }

    private func announceReset() -> Bool {
        guard let peak = resetToAnnounce, prefs.resetNotice else { return false }
        resetToAnnounce = nil
        guard !shouldStayQuiet() else { return false }
        feedback.alert(taps: 1, sound: nil)
        show(.limitReset(peak: peak, week: model.sevenDay))
        return true
    }

    /// All sessions together past the five-hour limit in Settings: one warning until it eases off.
    private func warnIfWindowHeavy() -> Bool {
        if snapshot.limits != nil {
            guard prefs.limitWarnPercent > 0, let five = model.fiveHour else { return false }
            let limit = Double(prefs.limitWarnPercent)
            // A new window, or the old one easing off, arms the warning again.
            if five.percent < limit - 10 || windowWarnedFor != five.resetsAt { windowWarned = false }
            guard five.percent >= limit, !windowWarned, !shouldStayQuiet() else { return false }
            windowWarned = true
            windowWarnedFor = five.resetsAt
            feedback.alert(taps: 2, sound: nil)
            show(.planLimit(five, week: model.sevenDay))
            return true
        }
        guard prefs.windowDollars > 0 else { return false }
        let limit = Double(prefs.windowDollars)
        let cost = snapshot.windowCost
        if cost < limit * 0.8 { windowWarned = false }
        guard cost >= limit, !windowWarned, !shouldStayQuiet() else { return false }
        windowWarned = true
        feedback.alert(taps: 2, sound: nil)
        show(.window(cost: cost))
        return true
    }

    /// A session whose context passed the limit in Settings: compaction is coming.
    private func warnIfContextFull() -> Bool {
        guard prefs.contextWarnPercent > 0 else { return false }
        var full: SessionRecord?
        for record in records {
            guard let percent = contextPercent(of: record) else { continue }
            if percent < prefs.contextWarnPercent - 15 { contextWarned.remove(record.id) }
            if percent >= prefs.contextWarnPercent, !contextWarned.contains(record.id) { full = record }
        }
        guard let full, !shouldStayQuiet() else { return false }
        contextWarned.insert(full.id)
        feedback.alert(taps: 1, sound: nil)
        show(.context(row(for: full)))
        return true
    }

    /// On a plan: the turn's estimated share of the five-hour limit. On API billing: dollars.
    private func costTexts(_ usage: TurnUsage?) -> (short: String?, long: String?) {
        guard let usage, usage.calls > 0 else { return (nil, nil) }
        if snapshot.limits != nil {
            guard let share = planShare(of: usage) else { return (nil, nil) }
            let text = LimitShare.text(share)
            let mark = share < 1 ? "" : "≈"
            return (mark + text, (mark.isEmpty ? "" : "≈ ") + text + " of 5h")
        }
        if usage.calls == usage.unpriced {
            let tokens = UsageText.tokens(usage.tokens) + " tokens"
            return (tokens, tokens)
        }
        let cost = "≈ " + UsageText.cost(usage.cost)
        return (cost, cost + " at API prices")
    }

    private func planShare(of usage: TurnUsage) -> Double? {
        perDollar.map { LimitShare.percent(cost: usage.cost, perDollar: $0) }
    }

    private func contextPercent(of record: SessionRecord) -> Int? {
        guard let usage = usage[record.id], usage.context > 0 else { return nil }
        let window = ContextWindow.size(model: usage.model, configured: snapshot.configuredContext)
        return ContextWindow.percent(usage.context, of: window)
    }

    // MARK: Pointer

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let inside = IslandLayout.isInteractive(mode: model.mode, anchor: model.anchor, x: p.x, y: p.y)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        trackPeek(inside: inside, at: p)
        guard model.hovering != inside else { return }
        model.hovering = inside
        // Opened with the shortcut, the list stays until Escape, the shortcut or a click elsewhere.
        if listOpen && !keyboardList {
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
        let frame = IslandLayout.panelFrame(for: model.mode, anchor: anchor).nsRect
        if panel.frame != frame { resizePanel(to: frame) }
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
        case "reminder", "heavy", "list-usage", "window", "context", "plan-limit", "reset", "keyboard":
            var waiting = fake("d2", .waiting, "Fix flaky crawler test", "\(home)/BackendProjects/seo-crawler", ago: 640,
                               wait: .question)
            waiting.turnStartedAt = now - 900
            var working = fake("d1", .working, "Booking API: pagination", "\(home)/BackendProjects/booking", ago: 400)
            working.turnStartedAt = now - 400
            var done = fake("d4", .done, "Notch island", "\(home)/BackendProjects/NordvaNotch", ago: 120,
                            reply: "Done. Tests pass and the new build is installed.")
            done.turnStartedAt = now - 480
            done.backgroundAgents = 2
            var heavyUsage = TurnUsage()
            heavyUsage.calls = 412
            heavyUsage.read = 41_000_000
            heavyUsage.write1h = 900_000
            heavyUsage.output = 96_000
            heavyUsage.cost = 12.4
            heavyUsage.agents = 6
            var light = TurnUsage()
            light.calls = 14
            light.read = 1_800_000
            light.cost = 0.62
            light.context = 410_000
            light.model = "claude-opus-5-5"
            heavyUsage.context = 880_000
            heavyUsage.model = "claude-opus-5-5"
            update(records: [waiting, working, done], titles: [:],
                   usage: UsageSnapshot(turns: ["d1": mode == "heavy" || mode == "context" ? heavyUsage : light, "d4": light],
                                        windowCost: 74.6, windowCalls: 1735,
                                        limits: PlanLimits(fiveHour: .init(percent: 61, resetsAt: now + 1900),
                                                           sevenDay: .init(percent: 17, resetsAt: now + 500_000), updatedAt: now - 600),
                                        fiveHour: LimitEstimate(percent: mode == "plan-limit" ? 82 : 64, resetsAt: now + 1900, exact: false),
                                        perDollar: 0.5))
            dismissBanner()
            switch mode {
            case "reminder": show(.reminder(row(for: waiting)))
            case "heavy": show(.heavy(row(for: working)))
            case "window": show(.window(cost: 152))
            case "plan-limit": show(.planLimit(model.fiveHour!, week: model.sevenDay))
            case "reset": show(.limitReset(peak: 86, week: model.sevenDay))
            case "keyboard":
                toggleListFromKeyboard()
                model.selectedRow = 1
            case "context": show(.context(row(for: working)))
            default:
                openList()
                collapseWork?.cancel()
            }
            bannerWork?.cancel()
        case "many", "many-scrolled":
            let names = ["Booking API: pagination", "Fix flaky crawler test", "RAG service: reranker", "Notch island",
                         "Spin admin hints", "Zipcode API comma", "Deckbell import", "Domain for Nordva", "Instagram page"]
            let many = names.enumerated().map { index, name in
                fake("m\(index)", index == 0 ? .working : .done, name, "\(home)/Projects/p\(index)", ago: Double(60 * (index + 1)))
            }
            update(records: many, titles: [:])
            toggleListFromKeyboard()
            if mode == "many-scrolled" { model.selectedRow = 7 }
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
