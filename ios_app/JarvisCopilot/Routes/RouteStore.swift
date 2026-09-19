import Foundation

/// Every recorded route, on the phone first: saved the moment a workout is,
/// sent to Jarvis Health when it can be (kept and retried when it can't),
/// and fetched back from the server for a workout this phone doesn't have
/// (a reinstall, another phone).
@MainActor
final class RouteStore: ObservableObject {
    static let shared = RouteStore()

    /// A saved route as the picker lists it, without loading it.
    struct Entry: Codable, Identifiable, Equatable {
        var start: Date
        var sport: Int
        var sportName: String
        var distance: Double
        var preview: String
        var id: String { RouteStore.key(start) }
    }

    /// A route waiting for the server.
    struct Pending: Codable, Equatable {
        var start: Date
        var device: String?
        var deviceID: String?
    }

    let directory: URL
    @Published private(set) var index: [Entry] = []

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        index = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))) ?? []
    }

    /// Whole seconds since 1970: a workout's start is its route's name.
    nonisolated static func key(_ start: Date) -> String { String(Int(start.timeIntervalSince1970.rounded())) }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private func url(_ start: Date) -> URL { directory.appendingPathComponent("\(Self.key(start)).json") }

    // MARK: Local

    /// Keeps the route and queues it for the server.
    func save(_ route: WorkoutRoute, for workout: RingWorkout, deviceID: String?) {
        write(route, start: workout.start)
        remember(workout, preview: workout.route?.preview ?? RouteMath.summary(route).preview)
        var queue = pending()
        queue.removeAll { Self.key($0.start) == Self.key(workout.start) }
        queue.append(Pending(start: workout.start, device: workout.device, deviceID: deviceID))
        store(queue)
    }

    func route(start: Date) -> WorkoutRoute? {
        guard let data = try? Data(contentsOf: url(start)) else { return nil }
        return try? JSONDecoder().decode(WorkoutRoute.self, from: data)
    }

    func hasRoute(start: Date) -> Bool { FileManager.default.fileExists(atPath: url(start).path) }

    /// Gone from the phone and from the queue (the server drops its copy
    /// with the workout).
    func delete(start: Date) {
        try? FileManager.default.removeItem(at: url(start))
        index.removeAll { $0.id == Self.key(start) }
        saveIndex()
        store(pending().filter { Self.key($0.start) != Self.key(start) })
    }

    private func write(_ route: WorkoutRoute, start: Date) {
        try? JSONEncoder().encode(route).write(to: url(start), options: .atomic)
    }

    private func remember(_ workout: RingWorkout, preview: String) {
        index.removeAll { $0.id == Self.key(workout.start) }
        index.append(Entry(start: workout.start, sport: workout.sport, sportName: workout.sportName,
                           distance: workout.route?.distanceMeters ?? workout.distanceMeters, preview: preview))
        index.sort { $0.start > $1.start }
        saveIndex()
    }

    private func saveIndex() {
        try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    // MARK: Server

    func pending() -> [Pending] {
        (try? JSONDecoder().decode([Pending].self, from: Data(contentsOf: pendingURL))) ?? []
    }

    private func store(_ queue: [Pending]) {
        try? JSONEncoder().encode(queue).write(to: pendingURL, options: .atomic)
    }

    private var flushing: Task<Void, Never>?

    /// Sends what is waiting, one flush at a time; what fails stays.
    func flush(client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) async {
        if let flushing { return await flushing.value }
        let task = Task { @MainActor in
            for item in pending() {
                guard let route = route(start: item.start) else {
                    store(pending().filter { $0 != item })
                    continue
                }
                do {
                    try await client.pushRoute(RouteMath.thin(route), start: item.start, device: item.device,
                                               deviceID: item.deviceID)
                    store(pending().filter { $0 != item })
                } catch {
                    continue
                }
            }
        }
        flushing = task
        await task.value
        flushing = nil
    }

    /// The route of a saved workout: this phone's copy, else the server's
    /// (kept here from then on).
    func load(_ workout: RingWorkout, client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) async
    -> WorkoutRoute? {
        if let local = route(start: workout.start) { return local }
        guard workout.route != nil,
              let fetched = try? await client.fetchRoute(start: workout.start, device: workout.device) else { return nil }
        write(fetched, start: workout.start)
        remember(workout, preview: workout.route?.preview ?? "")
        return fetched
    }
}

extension HealthClient {
    func pushRoute(_ route: WorkoutRoute, start: Date, device: String?, deviceID: String?) async throws {
        let body = try Self.serverJSON(route)
        _ = try await api.post("\(base)/workouts/route",
                               json: ["start": Self.instant.string(from: start), "device": device ?? "",
                                      "device_id": deviceID ?? "", "route": body],
                               timeout: 120)
    }

    func fetchRoute(start: Date, device: String?) async throws -> WorkoutRoute? {
        var query = ["start": Self.instant.string(from: start)]
        if let device { query["device"] = device }
        let object = try await api.get("\(base)/workouts/route", query: query).object()
        guard let raw = object["route"], !(raw is NSNull) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return HealthClient.instant.date(from: text) ?? start
        }
        return try decoder.decode(WorkoutRoute.self, from: JSONSerialization.data(withJSONObject: raw))
    }
}
