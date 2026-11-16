import Foundation
import Observation

/// REST for PC Stats (`/api/pc-stats`, webui/api/pc_stats_routes.py). Every route answers
/// 409 while the `pc-stats` Power integration is off.
struct PcStatsClient {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    private func query(_ deviceId: String?, _ extra: [String: String] = [:]) -> [String: String] {
        var q = extra
        if let deviceId, !deviceId.isEmpty { q["device_id"] = deviceId }
        return q
    }

    func live(deviceId: String?) async throws -> PcLive {
        PcLive(json: try await api.get("/api/pc-stats/live", query: query(deviceId), timeout: 10).object())
    }

    func summary(deviceId: String?) async throws -> PcSummary {
        PcSummary(json: try await api.get("/api/pc-stats/summary", query: query(deviceId), timeout: 15).object())
    }

    func history(deviceId: String?, key: String, from: Double, to: Double, points: Int = 300) async throws -> [PcPoint] {
        let q = query(deviceId, ["key": key, "from": String(Int(from)), "to": String(Int(to.rounded(.up))),
                                 "points": "\(points)"])
        return PcPoint.list(try await api.get("/api/pc-stats/history", query: q).object())
    }

    func sessions(deviceId: String?, limit: Int = 30) async throws -> [PcSession] {
        let body = try await api.get("/api/pc-stats/sessions", query: query(deviceId, ["limit": "\(limit)"])).object()
        return PcJSON.maps(body["sessions"]).compactMap(PcSession.init(json:))
    }

    func moments(deviceId: String?, from: Double, to: Double) async throws -> [PcMoment] {
        let q = query(deviceId, ["from": String(Int(from)), "to": String(Int(to.rounded(.up)))])
        let body = try await api.get("/api/pc-stats/moments", query: q).object()
        return PcJSON.maps(body["moments"]).compactMap(PcMoment.init(json:))
    }

    func energy(deviceId: String?, period: PcEnergyPeriod) async throws -> PcEnergy {
        PcEnergy(json: try await api.get("/api/pc-stats/energy", query: query(deviceId, ["period": period.rawValue])).object())
    }

    func catalog() async throws -> PcCatalog {
        PcCatalog(json: try await api.get("/api/pc-stats/catalog").object())
    }

    func dashboards() async throws -> [PcDashboard] {
        PcDashboard.list(try await api.get("/api/pc-stats/dashboards").object())
    }

    enum SaveResult: Equatable {
        case saved(PcDashboard)
        /// Someone else saved first: the server's current copy.
        case conflict(PcDashboard?)
        case invalid([String])
    }

    /// `PUT /dashboards/<id> {dashboard, rev}`: read by hand, since a 409 carries the current
    /// copy and a 400 the reasons.
    func save(_ dashboard: PcDashboard) async throws -> SaveResult {
        let body: [String: Any] = ["dashboard": dashboard.json, "rev": dashboard.rev as Any? ?? NSNull()]
        let path = "/api/pc-stats/dashboards/" + (dashboard.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dashboard.id)
        let req = try api.request("PUT", path, headers: ["Content-Type": "application/json"],
                                  body: try JSONSerialization.data(withJSONObject: body))
        let (data, http) = try await api.transport.send(req)
        return try Self.saveResult(status: http.statusCode, data: data)
    }

    static func saveResult(status: Int, data: Data) throws -> SaveResult {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300:
            guard let d = PcJSON.dict(obj["dashboard"]).flatMap(PcDashboard.init(json:)) else {
                throw APIError.badResponse("no dashboard in the reply")
            }
            return .saved(d)
        case 409 where obj["dashboard"] != nil || obj["error"] as? String == "changed elsewhere":
            return .conflict(PcJSON.dict(obj["dashboard"]).flatMap(PcDashboard.init(json:)))
        case 400:
            let errors = PcJSON.strings(obj["errors"])
            return .invalid(errors.isEmpty ? ["The server refused this dashboard."] : errors)
        default:
            throw APIError.http(status: status, message: APIError.message(status: status, body: data))
        }
    }

    func delete(dashboardId: String) async throws {
        let path = "/api/pc-stats/dashboards/" + (dashboardId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dashboardId)
        _ = try await api.delete(path)
    }
}

// MARK: - Page model

/// Which dashboard this phone shows (each device picks its own).
enum PcStatsPrefs {
    static let activeKey = "pcStats.active"

    static func active(_ defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: activeKey) }
    static func setActive(_ id: String?, _ defaults: UserDefaults = .standard) { defaults.set(id, forKey: activeKey) }

    /// The stored choice when it still exists, else the first dashboard.
    static func resolve(_ stored: String?, in dashboards: [PcDashboard]) -> PcDashboard? {
        dashboards.first { $0.id == stored } ?? dashboards.first
    }
}

/// One chart series: a reading over a window.
struct PcSeriesKey: Hashable {
    let key: String
    let window: Int
}

/// The stats page's state: live values every second while it's on screen, the dashboards,
/// chart history for the visible range, and the history sections.
@Observable
@MainActor
final class PcStatsModel {
    let deviceId: String
    let fallbackName: String

    private(set) var live: PcLive = .none
    private(set) var liveLoaded = false
    private(set) var catalog: PcCatalog = .empty
    private(set) var dashboards: [PcDashboard] = []
    private(set) var dashboardsLoaded = false
    private(set) var activeId: String?
    var range: PcRange = .live { didSet { if range != oldValue { Task { await loadSeries() } } } }
    private(set) var series: [PcSeriesKey: [PcPoint]] = [:]

    private(set) var sessions: [PcSession] = []
    private(set) var latestSession: PcSession?
    private(set) var moments: [PcMoment] = []
    private(set) var energy: PcEnergy?
    var energyPeriod: PcEnergyPeriod = .day { didSet { if energyPeriod != oldValue { Task { await loadEnergy() } } } }
    private(set) var health: [String: [PcPoint]] = [:]
    private(set) var historyLoaded = false

    /// A short note over the page ("Changed elsewhere — reloaded").
    var banner: String?
    private(set) var loadError: String?

    @ObservationIgnored private let client: PcStatsClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastLiveAt: Date?
    @ObservationIgnored private var lastSeriesLoad = Date.distantPast

    init(deviceId: String, name: String, client: PcStatsClient = PcStatsClient(), defaults: UserDefaults = .standard) {
        self.deviceId = deviceId
        self.fallbackName = name
        self.client = client
        self.defaults = defaults
        activeId = PcStatsPrefs.active(defaults)
    }

    var name: String { live.name.isEmpty ? fallbackName : live.name }

    var active: PcDashboard? { PcStatsPrefs.resolve(activeId, in: dashboards) }

    var widgetContext: PcWidgetContext {
        PcWidgetContext(live: live, catalog: catalog, range: range, points: { [weak self] in self?.points($0, widget: $1) ?? [] },
                        latestSession: latestSession, moments: moments, now: chartEnd)
    }

    /// Fills the model without the network (layout tests and rendered previews).
    func seed(live: PcLive, catalog: PcCatalog, dashboards: [PcDashboard], activeId: String? = nil,
              series: [PcSeriesKey: [PcPoint]] = [:], sessions: [PcSession] = [], moments: [PcMoment] = [],
              energy: PcEnergy? = nil, health: [String: [PcPoint]] = [:]) {
        self.live = live
        liveLoaded = true
        self.catalog = catalog
        self.dashboards = dashboards
        dashboardsLoaded = true
        self.activeId = activeId ?? dashboards.first?.id
        self.series = series
        self.sessions = sessions
        latestSession = sessions.first
        self.moments = moments
        self.energy = energy
        self.health = health
        historyLoaded = true
    }

    /// Where the charts end: now, or — Live, with the PC offline — its last sample, so the
    /// last minutes it reported stay on screen.
    var chartEnd: Date {
        if range == .live, !live.online, let at = live.at { return at }
        return Date()
    }

    func setActive(_ id: String) {
        activeId = id
        PcStatsPrefs.setActive(id, defaults)
        Task { await loadSeries() }
    }

    /// The PC's own fans and temperatures, for the library.
    var dynamicKeys: [String] {
        live.values.keys.filter { $0.hasPrefix("fan.") || $0.hasPrefix("temp.") }.sorted()
    }

    // MARK: Loading

    func start() async {
        async let a: Void = loadDashboards()
        async let b: Void = loadCatalog()
        async let c: Void = pollOnce()
        _ = await (a, b, c)
        await loadSeries()
        await loadHistory()
    }

    func refresh() async {
        await start()
    }

    func loadDashboards() async {
        do {
            dashboards = try await client.dashboards()
            dashboardsLoaded = true
            loadError = nil
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
        }
    }

    func loadCatalog() async {
        if let c = try? await client.catalog() { catalog = c }
    }

    /// The 1-second loop while the page is visible (5 s while the PC is offline). Ends when
    /// the calling task is cancelled.
    func pollLive() async {
        while !Task.isCancelled {
            await pollOnce()
            let wait: UInt64 = live.online ? 1_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: wait)
            if range != .live, Date().timeIntervalSince(lastSeriesLoad) > 60 { await loadSeries() }
        }
    }

    func pollOnce() async {
        do {
            let l = try await client.live(deviceId: deviceId)
            live = l
            liveLoaded = true
            appendLive(l)
        } catch {
            if !wasCancelled(error) { liveLoaded = true }
        }
    }

    /// Adds a fresh live sample to every Live series of its readings.
    private func appendLive(_ l: PcLive) {
        guard range == .live, let at = l.at, at != lastLiveAt else { return }
        lastLiveAt = at
        let t = at.timeIntervalSince1970
        for (sk, points) in series {
            guard let v = l.values[sk.key] else { continue }
            var pts = points
            if let last = pts.last, last.t >= t { continue }
            pts.append(PcPoint(t: t, avg: v))
            let floor = t - Double(sk.window)
            if let first = pts.firstIndex(where: { $0.t >= floor }), first > 0 { pts.removeFirst(first) }
            series[sk] = pts
        }
    }

    /// Fetches the chart history every visible widget needs for the current range.
    func loadSeries() async {
        guard let board = active else { return }
        lastSeriesLoad = Date()
        let now = chartEnd.timeIntervalSince1970
        var wanted = Set<PcSeriesKey>()
        for w in board.widgets where w.kind.hasChart || w.kind == .session {
            let window = range.window(for: w)
            let keys = w.kind == .chart || w.kind == .stats ? PcFormat.expand(w.readings, live: live)
                                                            : Array(w.readings.prefix(1))
            for k in keys { wanted.insert(PcSeriesKey(key: k, window: window)) }
        }
        var fresh: [PcSeriesKey: [PcPoint]] = [:]
        await withTaskGroup(of: (PcSeriesKey, [PcPoint]?).self) { group in
            for sk in wanted {
                group.addTask { [client, deviceId] in
                    let pts = try? await client.history(deviceId: deviceId, key: sk.key, from: now - Double(sk.window),
                                                        to: now, points: sk.window <= 600 ? sk.window / 2 : 240)
                    return (sk, pts)
                }
            }
            for await (sk, pts) in group { fresh[sk] = pts ?? series[sk] ?? [] }
        }
        series = fresh
    }

    func points(_ key: String, widget: PcWidget) -> [PcPoint] {
        series[PcSeriesKey(key: key, window: range.window(for: widget))] ?? []
    }

    // MARK: History sections

    func loadHistory() async {
        let now = Date().timeIntervalSince1970
        async let s = try? client.sessions(deviceId: deviceId, limit: 30)
        async let m = try? client.moments(deviceId: deviceId, from: now - 7 * 86_400, to: now)
        async let e: Void = loadEnergy()
        async let h: Void = loadHealth()
        let (sessions, moments) = await (s, m)
        _ = await (e, h)
        if let sessions { self.sessions = sessions; latestSession = sessions.first }
        if let moments { self.moments = moments.sorted { $0.t > $1.t } }
        historyLoaded = true
    }

    func loadEnergy() async {
        if let e = try? await client.energy(deviceId: deviceId, period: energyPeriod) { energy = e }
    }

    /// 90-day temperatures and fans, one point a day.
    func loadHealth() async {
        let now = Date().timeIntervalSince1970
        var keys = ["cpu.temp", "gpu.temp", "gpu.fan"]
        keys += dynamicKeys.filter { $0.hasPrefix("fan.") }.prefix(4)
        var out: [String: [PcPoint]] = [:]
        await withTaskGroup(of: (String, [PcPoint]?).self) { group in
            for k in keys {
                group.addTask { [client, deviceId] in
                    (k, try? await client.history(deviceId: deviceId, key: k, from: now - 90 * 86_400, to: now, points: 90))
                }
            }
            for await (k, pts) in group { if let pts, !pts.isEmpty { out[k] = pts } }
        }
        health = out
    }

    func sessionSeries(_ session: PcSession, key: String) async -> [PcPoint] {
        let end = (session.end ?? Date()).timeIntervalSince1970
        return (try? await client.history(deviceId: deviceId, key: key, from: session.start.timeIntervalSince1970,
                                          to: end, points: 240)) ?? []
    }

    func sessionMoments(_ session: PcSession) async -> [PcMoment] {
        let end = (session.end ?? Date()).timeIntervalSince1970
        return (try? await client.moments(deviceId: deviceId, from: session.start.timeIntervalSince1970, to: end)) ?? []
    }

    // MARK: Editing

    enum SaveOutcome: Equatable {
        case saved
        case conflict
        case invalid([String])
        case failed(String)
    }

    /// Writes a dashboard with its revision; a stale one reloads and says so.
    func save(_ dashboard: PcDashboard) async -> SaveOutcome {
        do {
            switch try await client.save(dashboard) {
            case .saved(let d):
                if let i = dashboards.firstIndex(where: { $0.id == d.id }) { dashboards[i] = d } else { dashboards.append(d) }
                // Only one dashboard can be the game one: the server cleared the others.
                if d.auto == "game" { await loadDashboards() }
                await loadSeries()
                return .saved
            case .conflict(let current):
                if let current, let i = dashboards.firstIndex(where: { $0.id == current.id }) { dashboards[i] = current }
                await loadDashboards()
                banner = PcStatsCopy.conflict
                await loadSeries()
                return .conflict
            case .invalid(let errors):
                return .invalid(errors)
            }
        } catch {
            return .failed(apiErrorMessage(error))
        }
    }

    /// A new, empty dashboard under a fresh id (rev null). The server refuses rev null over an
    /// existing id with 409, so a clash with one this phone hadn't seen tries another id.
    func createDashboard(name: String) async -> SaveOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var taken = Set(dashboards.map(\.id))
        for _ in 0..<3 {
            let board = PcDashboard(id: PcDashboard.newID(name: trimmed, taken: taken),
                                    name: trimmed.isEmpty ? "Dashboard" : trimmed)
            do {
                switch try await client.save(board) {
                case .saved(let d):
                    dashboards.append(d)
                    setActive(d.id)
                    return .saved
                case .conflict:
                    taken.insert(board.id)
                case .invalid(let errors):
                    return .invalid(errors)
                }
            } catch {
                return .failed(apiErrorMessage(error))
            }
        }
        await loadDashboards()
        return .failed("Couldn't find a free name for the dashboard. Try another name.")
    }

    func deleteDashboard(_ id: String) async -> String? {
        do {
            try await client.delete(dashboardId: id)
            dashboards.removeAll { $0.id == id }
            if activeId == id, let first = dashboards.first { setActive(first.id) }
            return nil
        } catch {
            return apiErrorMessage(error)
        }
    }
}

/// The Agents card's four numbers, every 5 s while the card is on screen.
@Observable
@MainActor
final class PcStatsSummaryModel {
    let deviceId: String
    private(set) var summary: PcSummary?
    @ObservationIgnored private let client: PcStatsClient

    init(deviceId: String, client: PcStatsClient = PcStatsClient()) {
        self.deviceId = deviceId
        self.client = client
    }

    func poll() async {
        while !Task.isCancelled {
            if let s = try? await client.summary(deviceId: deviceId) { summary = s }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
