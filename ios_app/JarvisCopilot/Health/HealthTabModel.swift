import Foundation

/// Which stretch of time the Health tab shows.
enum HealthSelection: Hashable {
    /// From the last wake-up to now, across midnight.
    case sinceWake
    /// One local calendar day, `yyyy-MM-dd`.
    case day(String)

    /// The key the history cache holds its day under.
    var cacheKey: String {
        switch self {
        case .sinceWake: return HealthTabModel.windowKey
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
    static let windowKey = "since-wake"

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

    init(client: HealthClient = HealthClient(spaceID: HealthSpace.shared), directory: URL? = nil) {
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
        case .sinceWake: return now?.battery
        case .day(let date): return batteries[date]
        }
    }

    func refresh(_ selection: HealthSelection) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            switch selection {
            case .sinceWake:
                let fresh = try await client.now()
                now = fresh
                cache.update(Self.windowKey) { $0 = fresh.day?.ringDay() ?? RingDay(date: Self.windowKey) }
                Self.writeNow(fresh, to: directory)
            case .day(let date):
                let response = try await client.day(date)
                cache.update(date) { $0 = response.day?.ringDay() ?? RingDay(date: date) }
                batteries[date] = response.battery
                await health.refresh(date: date)
            }
            loadedAt[selection.cacheKey] = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Ask the server to sync every linked wearable and score again, then reload.
    func runNow(_ selection: HealthSelection) async {
        isRefreshing = true
        _ = await health.runNow(date: RingDates.dayKey(Date()))
        isRefreshing = false
        await refresh(selection)
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
