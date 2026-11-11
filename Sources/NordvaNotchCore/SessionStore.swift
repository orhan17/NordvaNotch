import Foundation

/// One small JSON file per session. The hook writes, the app watches the folder and reads.
public struct SessionStore: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public static var defaultDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/NordvaNotch/sessions"
    }

    func path(for id: String) -> String {
        directory + "/" + id + ".json"
    }

    public func record(id: String) -> SessionRecord? {
        guard HookEvent.isSafeID(id), let data = FileManager.default.contents(atPath: path(for: id)) else { return nil }
        return SessionRecord.decode([UInt8](data))
    }

    public func all() -> [SessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { record(id: String($0.dropLast(5))) }
    }

    /// Temp file plus rename, so a reader never sees half a record.
    public func write(_ record: SessionRecord) {
        guard HookEvent.isSafeID(record.id) else { return }
        let target = path(for: record.id)
        let temp = directory + "/." + record.id + ".\(getpid()).tmp"
        let bytes = record.encoded()
        guard !bytes.isEmpty, FileManager.default.createFile(atPath: temp, contents: Data(bytes)) else { return }
        if rename(temp, target) != 0 { unlink(temp) }
    }

    public func remove(id: String) {
        guard HookEvent.isSafeID(id) else { return }
        unlink(path(for: id))
    }

    /// Read, apply and write under one lock, so two hooks of the same session cannot interleave.
    @discardableResult
    public func handle(_ event: HookEvent, at now: Double) -> SessionRecord.Update {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lock = open(directory + "/.lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }

        let update = SessionRecord.apply(event, to: record(id: event.sessionID), at: now)
        switch update {
        case .write(let record): write(record)
        case .remove: remove(id: event.sessionID)
        case .ignore: break
        }
        return update
    }

    /// Deletes records nobody has touched for `SessionBoard.pruneAfter`.
    public func prune(now: Double) {
        for record in all() where now - record.updatedAt > SessionBoard.pruneAfter {
            remove(id: record.id)
        }
    }
}
