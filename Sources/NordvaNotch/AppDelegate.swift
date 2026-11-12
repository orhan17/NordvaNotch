import AppKit
import NordvaNotchCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let demo: String?
    private let prefs = Preferences()
    private lazy var feedback = Feedback(prefs: prefs)
    private lazy var island = IslandController(prefs: prefs, feedback: feedback)
    private let monitor = SessionMonitor(store: SessionStore(directory: SessionStore.defaultDirectory))
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var hotKeyShortcut: HotKey.Shortcut?
    private lazy var settingsWindow = SettingsWindowController(prefs: prefs, preview: { [weak self] in self?.island.preview() })

    init(demo: String?) {
        self.demo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        island.openSettings = { [weak self] in self?.openSettings() }
        island.removeSessions = { [weak self] ids in self?.monitor.remove(ids: ids) }
        island.contextMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        island.persistsTimer = demo == nil
        island.start()
        prefs.onChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()

        if let demo {
            if demo == "settings" { openSettings() } else { island.demo(demo) }
            return
        }
        monitor.onChange = { [weak self] records, titles, usage in
            self?.island.update(records: records, titles: titles, usage: usage)
        }
        monitor.start()
    }

    private func applyPreferences() {
        island.applyPreferences()
        if hotKeyShortcut != prefs.shortcut, demo == nil {
            hotKey = nil
            hotKey = HotKey(prefs.shortcut) { [weak self] in self?.island.toggleListFromKeyboard() }
            hotKeyShortcut = prefs.shortcut
            if prefs.shortcut != .off {
                NSLog("NordvaNotch: shortcut %@ %@", prefs.shortcut.title, hotKey == nil ? "could not be registered" : "registered")
            }
        }
        if prefs.menuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.menuBarImage()
            item.button?.toolTip = "NordvaNotch"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !prefs.menuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        makeMenu().items.forEach { item in
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let rows = island.sessionRows
        if rows.isEmpty {
            let empty = NSMenuItem(title: "No Claude Code sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for row in rows {
            let item = NSMenuItem(title: row.title, action: #selector(openSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.image = Self.dot(Palette.nsColor(for: row.status, stalled: row.stalled))
            let detail = NSAttributedString(
                string: "  \(row.statusText)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 12)]
            )
            let title = NSMutableAttributedString(string: row.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(detail)
            item.attributedTitle = title
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Sessions", action: #selector(showSessions), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let timer = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        if island.timerEnd != nil {
            let stop = NSMenuItem(title: "Stop Timer", action: #selector(stopTimer), keyEquivalent: "")
            stop.target = self
            timerMenu.addItem(stop)
            timerMenu.addItem(.separator())
        }
        for minutes in [5, 10, 15, 25, 45, 60] {
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            timerMenu.addItem(item)
        }
        timer.submenu = timerMenu
        if prefs.timerEnabled || island.timerEnd != nil { menu.addItem(timer) }

        let clear = NSMenuItem(title: "Clear Finished Sessions", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = rows.contains { $0.status != .working && $0.status != .waiting }
        menu.addItem(clear)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit NordvaNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.autoenablesItems = false
        return menu
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = island.sessionRows.first(where: { $0.id == id }) else { return }
        island.open(row)
    }

    @objc private func showSessions() {
        island.openList()
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        island.startTimer(minutes: sender.tag)
    }

    @objc private func stopTimer() {
        island.stopTimer()
    }

    @objc private func clearFinished() {
        let ids = monitor.records.filter { $0.status != .working && $0.status != .waiting }.map(\.id)
        monitor.remove(ids: ids)
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    // MARK: Images

    /// The island hanging from the top edge, as a template image.
    private static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.4
            NSColor.black.setStroke()
            frame.stroke()
            let island = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 9.5, width: 7, height: 5), xRadius: 2, yRadius: 2)
            NSColor.black.setFill()
            island.fill()
            NSBezierPath(rect: NSRect(x: 5.5, y: 12, width: 7, height: 2.5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}

extension Palette {
    static func nsColor(for status: SessionStatus, stalled: Bool) -> NSColor {
        NSColor(color(for: status, stalled: stalled))
    }
}
