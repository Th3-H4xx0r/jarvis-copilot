import Foundation

/// Which stretch of time the Health tab shows.
enum HealthSelection: Hashable {
    /// From falling asleep last night to now: the night, its charge and the
    /// waking day on one timeline that does not reset at midnight.
    case today
    /// One local calendar day, `yyyy-MM-dd`.
    case day(String)

    /// The key the history cache holds its day under.
    var cacheKey: String {
        switch self {
        case .today: return HealthTabModel.windowKey
        case .day(let date): return date
        }
    }
}

/// Loads Jarvis Health for the Health tab and keeps the phone's offline copy.
///
/// The server merges every linked wearable; this only fetches and caches. Days
/// land in a `RingHistoryStore` of their own, so the ring's chart cards draw
/// them unchanged and the tab still shows the last copy with no signal.
@MainActor
final class HealthTabModel: ObservableObject {
    static let windowKey = "today"

    @Published private(set) var now: HealthNow?
    @Published private(set) var batteries: [String: HealthBattery] = [:]
    @Published private(set) var loadedAt: [String: Date] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?

    let cache: RingHistoryStore
    /// Scores, the model's analysis and the settings, from the same integration.
    let health: HealthStore
    private let client: HealthClient
    private let directory: URL
    /// The ring's own history, for the spot readings the server's day lacks.
    private let spots: () -> RingHistoryStore?

    init(client: HealthClient = HealthClient(spaceID: HealthSpace.shared), directory: URL? = nil,
         spots: @escaping () -> RingHistoryStore? = { nil }) {
        self.spots = spots
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthTab", isDirectory: true)
        self.client = client
        self.directory = base
        cache = RingHistoryStore(directory: base.appendingPathComponent("days", isDirectory: true))
        health = HealthStore(spaceID: HealthSpace.shared, client: client,
                             directory: base.appendingPathComponent("scores", isDirectory: true))
        now = Self.readNow(from: base)
    }

    /// The battery for what is on screen.
    func battery(for selection: HealthSelection) -> HealthBattery? {
        switch selection {
        case .today: return now?.battery
        case .day(let date): return batteries[date]
        }
    }

    func refresh(_ selection: HealthSelection) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            switch selection {
            case .today:
                let fresh = try await client.now()
                now = fresh
                cache.update(Self.windowKey) { $0 = fresh.day?.ringDay() ?? RingDay(date: Self.windowKey) }
                Self.writeNow(fresh, to: directory)
                // Last night's sleep score and the analysis live on the day it ended.
                await health.refresh(date: Self.scoresDate(fresh))
            case .day(let date):
                let response = try await client.day(date)
                cache.update(date) { $0 = response.day?.ringDay() ?? RingDay(date: date) }
                batteries[date] = response.battery
                await health.refresh(date: date)
            }
            mergeSpots(selection)
            loadedAt[selection.cacheKey] = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The day whose scores describe today: the one last night ended on.
    nonisolated static func scoresDate(_ now: HealthNow?) -> String {
        RingDates.dayKey(now?.wake ?? now?.end ?? Date())
    }

    /// Ask the server to sync every linked wearable and score again, then reload.
    func runNow(_ selection: HealthSelection) async {
        isRefreshing = true
        _ = await health.runNow(date: RingDates.dayKey(Date()))
        isRefreshing = false
        await refresh(selection)
    }

    /// The ring's own spot readings — Measure results and the numbers it
    /// sends while measuring — which the server's day does not carry. Today's
    /// window is on the clock of the midnight before bedtime, so each of the
    /// ring's days is moved onto it.
    func mergeSpots(_ selection: HealthSelection) {
        guard let ring = spots() else { return }
        switch selection {
        case .day(let date):
            cache.update(date) { $0.addSpots(from: ring.day(date), shift: 0) }
        case .today:
            guard let now else { return }
            let calendar = Calendar.current
            let anchor = calendar.startOfDay(for: now.start)
            let first = Int(now.start.timeIntervalSince(anchor) / 60)
            var midnight = anchor
            while midnight <= Date() {
                let shift = Int(midnight.timeIntervalSince(anchor) / 60)
                let day = ring.day(RingDates.dayKey(midnight))
                cache.update(Self.windowKey) { $0.addSpots(from: day, shift: shift, from: first) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
                midnight = next
            }
        }
    }

    /// Put a window on screen without a server: previews and the render harness.
    func seed(now: HealthNow, day: RingDay) {
        self.now = now
        cache.update(Self.windowKey) { $0 = day }
        loadedAt[Self.windowKey] = Date()
    }

    // MARK: Data sources

    func devices() async -> [HealthRosterDevice] {
        (try? await HealthClient.devices(api: client.api)) ?? []
    }

    /// Link or unlink a wearable, then reload what is on screen without it.
    func setLinked(_ device: String, _ linked: Bool, reload selection: HealthSelection) async {
        do {
            try await client.setLinked(device, linked)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh(selection)
    }

    // MARK: Offline copy of the window

    private static func nowURL(_ base: URL) -> URL { base.appendingPathComponent("now.json") }

    private static func readNow(from base: URL) -> HealthNow? {
        guard let data = try? Data(contentsOf: nowURL(base)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HealthNow.self, from: data)
    }

    private static func writeNow(_ now: HealthNow, to base: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? encoder.encode(now).write(to: nowURL(base), options: .atomic)
    }
}

extension RingDay {
    /// Another day's spot readings, moved onto this day's clock and kept from
    /// minute `first` on.
    mutating func addSpots(from other: RingDay, shift: Int, from first: Int = 0) {
        func moved(_ values: [RingTimedValue]) -> [RingTimedValue] {
            values.map { RingTimedValue(minute: $0.minute + shift, value: $0.value) }.filter { $0.minute >= first }
        }
        manualHeartRate = RingDay.merged(manualHeartRate, moved(other.manualHeartRate))
        instantHeartRate = RingDay.merged(instantHeartRate, moved(other.instantHeartRate))
        manualSpO2 = RingDay.merged(manualSpO2, moved(other.manualSpO2))
        instantSpO2 = RingDay.merged(instantSpO2, moved(other.instantSpO2))
        instantTemperature = RingDay.merged(instantTemperature, moved(other.instantTemperature))
    }
}
