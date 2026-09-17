import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The phone's cache of what the server computed, and the widget's source.
///
/// The card must render instantly and offline, so every fetch is written to
/// disk and to the shared app group. A cached day is shown with its age rather
/// than hidden: old numbers labelled old beat an empty card.
@MainActor
final class HealthStore: ObservableObject {
    @Published private(set) var scores: [String: HealthScores] = [:]
    @Published private(set) var settings: HealthSettings?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var fetchedAt: [String: Date] = [:]

    /// How old a cached day may be before the card calls it stale.
    static let freshFor: TimeInterval = 2 * 60 * 60

    private let spaceID: String
    private let client: HealthClient
    private let directory: URL

    init(spaceID: String, client: HealthClient? = nil, directory: URL? = nil) {
        self.spaceID = spaceID
        self.client = client ?? HealthClient(spaceID: spaceID)
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("Health/\(spaceID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadCache()
    }

    func scores(for date: String) -> HealthScores? { scores[date] }

    /// True when what we are showing for `date` came from before `freshFor`.
    func isStale(_ date: String) -> Bool {
        if scores[date]?.stale == true { return true }
        guard let at = fetchedAt[date] else { return scores[date] != nil }
        return Date().timeIntervalSince(at) > Self.freshFor
    }

    func age(of date: String) -> TimeInterval? {
        fetchedAt[date].map { Date().timeIntervalSince($0) }
    }

    /// Fetch a day's scores. On failure the cache stands and the error is kept
    /// for the card to mention, rather than thrown away or thrown at the user.
    func refresh(date: String) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if let fresh = try await client.scores(date: date) {
                scores[date] = fresh
                fetchedAt[date] = Date()
                lastError = nil
                write(fresh, for: date)
                publishSnapshot(fresh)
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSettings() async {
        do {
            settings = try await client.settings()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func updateSettings(_ updates: [String: Any]) async -> Bool {
        do {
            settings = try await client.updateSettings(updates)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func runNow(date: String) async -> Bool {
        do {
            _ = try await client.runNow()
            await refresh(date: date)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Cache

    private func fileURL(_ date: String) -> URL { directory.appendingPathComponent("\(date).json") }

    private func write(_ scores: HealthScores, for date: String) {
        guard let data = try? JSONEncoder().encode(CachedScores(scores: scores, fetchedAt: Date())) else { return }
        try? data.write(to: fileURL(date), options: .atomic)
    }

    private func loadCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let cached = try? JSONDecoder().decode(CachedScores.self, from: data) else { continue }
            let date = url.deletingPathExtension().lastPathComponent
            scores[date] = cached.scores
            fetchedAt[date] = cached.fetchedAt
        }
    }

    private struct CachedScores: Codable {
        var scores: HealthScores
        var fetchedAt: Date
    }

    // MARK: Widget

    /// Hand the widget the numbers. It never talks to the ring or the network.
    private func publishSnapshot(_ scores: HealthScores) {
        HealthSnapshot(
            date: scores.date,
            health: scores.health.value,
            band: scores.health.band,
            sleep: scores.sleep.value,
            recovery: scores.recovery.value,
            body: scores.body.value,
            activity: scores.activity.value,
            analysis: scores.analysis,
            generatedAt: scores.generatedAt ?? Date(),
            stale: scores.stale
        ).write()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: HealthSnapshot.widgetKind)
        #endif
    }
}
