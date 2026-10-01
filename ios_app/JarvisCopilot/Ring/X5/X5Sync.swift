import Foundation

/// Where each X5 history store was last read up to: the timestamp of the newest entry already
/// stored. The ring only honours a timestamp it actually holds, so it is always one of its own.
@MainActor
final class X5Cursors {
    private let deviceID: String
    private let defaults: UserDefaults

    init(deviceID: String, defaults: UserDefaults = .standard) {
        self.deviceID = deviceID
        self.defaults = defaults
    }

    private func key(_ kind: X5HistoryKind) -> String {
        "jc.x5.cursor.\(deviceID).\(String(format: "%02X", kind.rawValue))"
    }

    func newest(_ kind: X5HistoryKind) -> Date? {
        let seconds = defaults.double(forKey: key(kind))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Only ever forward: a page of older entries never winds the cursor back.
    func advance(_ kind: X5HistoryKind, to date: Date) {
        if let current = newest(kind), current >= date { return }
        defaults.set(date.timeIntervalSince1970, forKey: key(kind))
    }

    func reset() {
        X5HistoryKind.allCases.forEach { defaults.removeObject(forKey: key($0)) }
    }
}

extension X5HistoryKind {
    /// Read on every sync. Manual SpO₂ and workouts join when the ring proves it has them.
    static let syncOrder: [X5HistoryKind] = [.dayTotals, .stepBlocks, .sleep, .continuousHR, .singleHR, .hrv,
                                             .temperature, .autoSpO2]

    /// How long the newest entry of this store can still grow after its timestamp — the step
    /// block being filled, the sleep chunk being written. The cursor never stops on one of those.
    var span: TimeInterval {
        switch self {
        case .stepBlocks: return 10 * 60
        case .sleep: return 2 * 3600
        case .continuousHR: return 75
        default: return 0
        }
    }
}

/// Pulls the X5's history stores into the day store.
///
/// Each store is read from its cursor (`<op> 00 <timestamp>`), fifty entries a page (`<op> 02`
/// for the next), until `<op> FF` or a short page. A page is stored before its cursor moves, so a
/// link dropping mid-sync costs nothing: the next sync asks again from the last stored entry.
@MainActor
final class X5Sync: ObservableObject {
    static let pageSize = 50
    /// A store can't hold more than this many pages; a ring that keeps answering is ignored past it.
    static let maxPages = 40

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?

    var onDaysChanged: ((Set<String>) -> Void)?
    /// Workout records go to the workout history, not the day store.
    var onWorkouts: (([X5WorkoutRecord]) -> Void)?
    /// Stores read beyond `syncOrder` (probed ones).
    var extraKinds: [X5HistoryKind] = []

    private let transport: RingTransport
    private let storeProvider: () -> RingHistoryStore?
    private let cursorProvider: () -> X5Cursors?
    private let calendar: Calendar
    private let now: () -> Date

    init(transport: RingTransport, store: @escaping () -> RingHistoryStore?, cursors: @escaping () -> X5Cursors?,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.storeProvider = store
        self.cursorProvider = cursors
        self.calendar = calendar
        self.now = now
    }

    var isStale: Bool { lastSync.map { now().timeIntervalSince($0) > 600 } ?? true }

    /// Reads every store (or `kinds`) and returns the day keys that changed.
    @discardableResult
    func sync(kinds: [X5HistoryKind]? = nil) async -> Result<Set<String>, Error> {
        guard !isSyncing else { return .success([]) }
        guard let store = storeProvider(), let cursors = cursorProvider() else { return .failure(RingError.notConnected) }
        isSyncing = true
        defer { isSyncing = false }
        var touched: Set<String> = []
        var failure: Error?
        for kind in kinds ?? (X5HistoryKind.syncOrder + extraKinds) {
            do {
                touched.formUnion(try await read(kind, store: store, cursors: cursors))
            } catch RingError.notConnected {
                failure = RingError.notConnected
                break
            } catch {
                failure = failure ?? error
                JcLog.devices.notice("x5: \(String(format: "%02X", kind.rawValue), privacy: .public) read failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        if failure == nil || !touched.isEmpty { lastSync = now() }
        lastError = failure?.localizedDescription
        if !touched.isEmpty { onDaysChanged?(touched) }
        if let failure, touched.isEmpty { return .failure(failure) }
        return .success(touched)
    }

    private func read(_ kind: X5HistoryKind, store: RingHistoryStore, cursors: X5Cursors) async throws -> Set<String> {
        // Day totals are fifteen small entries: always read whole, so today's keeps moving.
        var after = kind == .dayTotals ? nil : cursors.newest(kind)
        var request = RingRequest.x5History(kind, after: after, calendar: calendar)
        var touched: Set<String> = []
        var seen: [Date] = []
        var pages = 0
        while pages < Self.maxPages {
            let frames: [RingInbound]
            do {
                frames = try await transport.perform(request, until: .packets(X5Frames.isEnd))
            } catch RingError.rejected where after != nil {
                // The ring no longer holds that entry (overwritten, or its history cleared).
                after = nil
                request = .x5History(kind, after: nil, calendar: calendar)
                continue
            }
            pages += 1
            let entries = frames.filter { !X5Frames.isEnd($0) }.map(\.payload)
            if entries.isEmpty { break }
            let (batch, dates, workouts) = decode(entries, kind: kind)
            if !batch.isEmpty { touched.formUnion(X5DayMapper.apply(batch, to: store, calendar: calendar)) }
            if !workouts.isEmpty { onWorkouts?(workouts) }
            seen += dates
            guard entries.count >= Self.pageSize else { break }
            request = .x5HistoryNext(kind)
        }
        // Only once the store has been read to its end: pages may come newest first, and an
        // interrupted read must be asked again from where the last whole one stopped.
        if let newest = cursorDate(seen, kind: kind) { cursors.advance(kind, to: newest) }
        return touched
    }

    /// The newest entry the ring has finished writing.
    private func cursorDate(_ dates: [Date], kind: X5HistoryKind) -> Date? {
        let settled = now().addingTimeInterval(-kind.span)
        return dates.filter { $0 <= settled }.max()
    }

    private func decode(_ entries: [[UInt8]], kind: X5HistoryKind) -> (X5Batch, [Date], [X5WorkoutRecord]) {
        var batch = X5Batch()
        var dates: [Date] = []
        var workouts: [X5WorkoutRecord] = []
        for p in entries {
            switch kind {
            case .dayTotals:
                if let t = X5Decode.dayTotal(p) { batch.totals.append(t) }
            case .stepBlocks:
                if let b = X5Decode.stepBlock(p, calendar: calendar) { batch.blocks.append(b); dates.append(b.start) }
            case .sleep:
                if let s = X5Decode.sleep(p, calendar: calendar) { batch.sleep.append(s); dates.append(s.start) }
            case .continuousHR:
                if let h = X5Decode.continuousHR(p, calendar: calendar) { batch.hr.append(h); dates.append(h.start) }
            case .singleHR:
                if let r = X5Decode.reading(p, calendar: calendar) { batch.singleHR.append(r); dates.append(r.date) }
            case .hrv:
                if let h = X5Decode.hrv(p, calendar: calendar) { batch.hrv.append(h); dates.append(h.date) }
            case .temperature:
                // A reading taken off the finger is dropped by the decoder but still moves the cursor.
                if let d = X5Decode.date(p, at: 2, calendar: calendar) { dates.append(d) }
                if let t = X5Decode.temperature(p, calendar: calendar) { batch.temperature.append(t) }
            case .autoSpO2:
                if let r = X5Decode.reading(p, calendar: calendar) { batch.spo2.append(r); dates.append(r.date) }
            case .manualSpO2:
                if let r = X5Decode.reading(p, calendar: calendar) { batch.manualSpO2.append(r); dates.append(r.date) }
            case .workouts:
                if let w = X5Decode.workout(p, calendar: calendar) { workouts.append(w); dates.append(w.start) }
            }
        }
        return (batch, dates, workouts)
    }
}
