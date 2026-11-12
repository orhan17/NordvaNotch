import Foundation
import NordvaNotchCore

/// Watches the sessions folder the hook writes to, and reads transcript titles and usage off the main thread.
final class SessionMonitor {
    let store: SessionStore
    var onChange: (([SessionRecord], [String: String], UsageSnapshot) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    private var ticker: Timer?
    private let titleQueue = DispatchQueue(label: "NordvaNotch.titles", qos: .utility)
    private var titleCache: [String: (modified: Date, title: String?)] = [:]
    private let tracker = UsageTracker()
    private(set) var records: [SessionRecord] = []
    private(set) var titles: [String: String] = [:]
    private(set) var usage = UsageSnapshot()

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        // Usage, reminders, stalled sessions and pruning need a clock as well.
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.prune(now: Date().timeIntervalSince1970)
            self.reload()
        }
        store.prune(now: Date().timeIntervalSince1970)
        reload()
    }

    /// A hook writes a temp file and renames it: two events for one change, so coalesce them.
    private func scheduleReload() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pending = false
            self?.reload()
        }
    }

    func reload() {
        records = store.all()
        onChange?(records, titles, usage)
        refreshDetails(for: records)
    }

    func remove(ids: [String]) {
        ids.forEach(store.remove(id:))
        reload()
    }

    private func refreshDetails(for records: [SessionRecord]) {
        let jobs = records.compactMap { record in record.transcriptPath.map { (record.id, $0) } }
        titleQueue.async { [weak self] in
            guard let self else { return }
            var found: [String: String] = [:]
            for (id, path) in jobs {
                if let title = self.title(atPath: path) { found[id] = title }
            }
            let usage = self.tracker.refresh(records: records, now: Date().timeIntervalSince1970)
            DispatchQueue.main.async {
                guard found != self.titles || usage != self.usage else { return }
                self.titles = found
                self.usage = usage
                self.onChange?(self.records, found, usage)
            }
        }
    }

    /// Runs on `titleQueue` only.
    private func title(atPath path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        if let cached = titleCache[path], cached.modified == modified { return cached.title }

        var title: String?
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            // The desktop app rewrites the title line every turn, so the end of the file has it.
            for window in [UInt64(256 * 1024), UInt64(4 * 1024 * 1024)] {
                let start = size > window ? size - window : 0
                try? handle.seek(toOffset: start)
                if let data = try? handle.read(upToCount: Int(size - start)) {
                    title = SessionNaming.customTitle(inTranscriptTail: String(decoding: data, as: UTF8.self))
                }
                if title != nil || start == 0 { break }
            }
        }
        titleCache[path] = (modified, title)
        return title
    }
}
