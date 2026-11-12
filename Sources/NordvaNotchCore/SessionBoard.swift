/// Ordering, "seen" marks and alert decisions for the list. The app keeps the state, this decides.
public enum SessionBoard {
    /// Sessions untouched for this long drop out of the list (the file stays until `pruneAfter`).
    public static let hideAfter: Double = 12 * 3600
    public static let pruneAfter: Double = 3 * 86400
    /// A working session with no hook activity for this long is probably interrupted.
    public static let stalledAfter: Double = 15 * 60

    public static func isUnseen(_ record: SessionRecord, seen: [String: Double]) -> Bool {
        record.status.wantsAttention && record.statusSince > (seen[record.id] ?? 0)
    }

    public static func isStalled(_ record: SessionRecord, now: Double) -> Bool {
        record.status == .working && now - record.updatedAt > stalledAfter
    }

    static func rank(_ record: SessionRecord, seen: [String: Double]) -> Int {
        switch record.status {
        case .waiting: return 0
        case .failed, .done: return isUnseen(record, seen: seen) ? 1 : 3
        case .working: return 2
        case .idle: return 4
        }
    }

    /// Needs-you first, then unseen results, then running work, then the rest; newest first inside each group.
    public static func ordered(_ records: [SessionRecord], seen: [String: Double], now: Double) -> [SessionRecord] {
        records
            .filter { now - $0.updatedAt < hideAfter || isUnseen($0, seen: seen) || $0.status == .waiting }
            .sorted {
                let (a, b) = (rank($0, seen: seen), rank($1, seen: seen))
                if a != b { return a < b }
                if $0.statusSince != $1.statusSince { return $0.statusSince > $1.statusSince }
                return $0.id < $1.id
            }
    }

    /// Records whose current status has not been announced yet. Anything older than `launch`
    /// happened while the app was not running and is shown quietly instead.
    public static func newAlerts(in records: [SessionRecord], announced: [String: Double], launch: Double) -> [SessionRecord] {
        records
            .filter { $0.status.wantsAttention && $0.statusSince > max(announced[$0.id] ?? 0, launch) }
            .sorted { $0.statusSince < $1.statusSince }
    }

    /// Sessions to nudge again: waiting for you, or finished and unseen, for `after` seconds.
    /// Each status is reminded once, and only when it came due after the app started.
    public static func dueReminders(
        in records: [SessionRecord], seen: [String: Double], reminded: [String: Double],
        now: Double, after: Double, launch: Double
    ) -> [SessionRecord] {
        guard after > 0 else { return [] }
        return records
            .filter { record in
                let waiting = record.status == .waiting
                let unseenResult = (record.status == .done || record.status == .failed) && isUnseen(record, seen: seen)
                guard waiting || unseenResult else { return false }
                let due = record.statusSince + after
                return due <= now && due >= launch && reminded[record.id] != record.statusSince
            }
            .sorted { $0.statusSince < $1.statusSince }
    }

    /// How long the current turn has run, or ran: up to now while working, up to the stop otherwise.
    public static func turnSeconds(of record: SessionRecord, now: Double) -> Double? {
        guard let start = record.turnStartedAt else { return nil }
        switch record.status {
        case .working: return now - start
        case .done, .failed, .waiting: return max(0, record.statusSince - start)
        case .idle: return nil
        }
    }

    public static func unseenCount(_ records: [SessionRecord], seen: [String: Double]) -> Int {
        records.filter { isUnseen($0, seen: seen) }.count
    }
}
