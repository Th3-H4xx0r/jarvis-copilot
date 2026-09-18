import Foundation

/// A sport the ring tracks as a workout, by the id its firmware knows it by
/// (the QRing app's list). Outdoor sports also use the phone's GPS.
struct RingSport: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let symbol: String
    var outdoor = false

    /// The eight most people want, in the picker's grid.
    static let common: [RingSport] = [
        .init(id: 7, name: "Run", symbol: "figure.run", outdoor: true),
        .init(id: 4, name: "Walk", symbol: "figure.walk", outdoor: true),
        .init(id: 9, name: "Cycle", symbol: "figure.outdoor.cycle", outdoor: true),
        .init(id: 8, name: "Hike", symbol: "figure.hiking", outdoor: true),
        .init(id: 88, name: "Strength", symbol: "figure.strengthtraining.traditional"),
        .init(id: 22, name: "Yoga", symbol: "figure.yoga"),
        .init(id: 6, name: "Swim", symbol: "figure.pool.swim"),
        .init(id: 5, name: "Jump rope", symbol: "figure.jumprope"),
    ]

    /// Everything else the ring knows, under More.
    static let more: [RingSport] = [
        .init(id: 42, name: "Trail run", symbol: "figure.run", outdoor: true),
        .init(id: 40, name: "Treadmill", symbol: "figure.run"),
        .init(id: 41, name: "Indoor walk", symbol: "figure.walk"),
        .init(id: 24, name: "Indoor cycle", symbol: "figure.indoor.cycle"),
        .init(id: 26, name: "Elliptical", symbol: "figure.elliptical"),
        .init(id: 27, name: "Rowing", symbol: "figure.rower"),
        .init(id: 80, name: "Stair climber", symbol: "figure.stair.stepper"),
        .init(id: 89, name: "Interval training", symbol: "figure.highintensity.intervaltraining"),
        .init(id: 94, name: "Pilates", symbol: "figure.pilates"),
        .init(id: 35, name: "Dance", symbol: "figure.dance"),
        .init(id: 31, name: "Basketball", symbol: "figure.basketball"),
        .init(id: 32, name: "Football", symbol: "figure.soccer"),
        .init(id: 29, name: "Tennis", symbol: "figure.tennis"),
        .init(id: 21, name: "Badminton", symbol: "figure.badminton"),
        .init(id: 30, name: "Golf", symbol: "figure.golf"),
        .init(id: 20, name: "Climbing", symbol: "figure.climbing"),
        .init(id: 10, name: "Other", symbol: "figure.mixed.cardio"),
    ]

    static let all = common + more

    static func withID(_ id: Int) -> RingSport {
        all.first { $0.id == id } ?? RingSport(id: id, name: "Workout", symbol: "figure.mixed.cardio")
    }

    /// "run", "a run", "running", "outdoor walk" → the sport, for voice.
    static func named(_ text: String) -> RingSport? {
        let words = text.lowercased()
        let aliases: [(String, Int)] = [("jog", 7), ("running", 7), ("trail", 42), ("treadmill", 40),
                                        ("walking", 4), ("bike", 9), ("cycling", 9), ("spin", 24), ("hiking", 8),
                                        ("weights", 88), ("lifting", 88), ("gym", 88), ("swimming", 6),
                                        ("skipping", 5), ("rope", 5), ("row", 27), ("hiit", 89), ("stairs", 80)]
        if let hit = all.first(where: { words.contains($0.name.lowercased()) }) { return hit }
        if let alias = aliases.first(where: { words.contains($0.0) }) { return withID(alias.1) }
        return nil
    }
}

/// One second of a workout as the ring reports it (`0x78`, pushed each second
/// while a session exists).
struct RingSportTick: Equatable {
    enum State: Int { case paused = 1, running = 2, ended = 3 }

    var sport: Int
    var state: State
    /// Active seconds — the ring stops counting while paused.
    var elapsed: Int
    /// Nil until the sensor has a reading (the ring sends 0).
    var heartRate: Int?
    var steps: Int
    var distanceMeters: Int
    var kilocalories: Double
}

/// What the phone tells the ring (`0x77` `[status, sport]`). `5`, a
/// phone-side distance sync, exists in the firmware but QRing never sends it.
enum RingSportCommand: UInt8 {
    case start = 1, pause = 2, resume = 3, stop = 4, query = 6
}

extension RingDecode {
    /// `[sport, state, elapsed u16, hr, steps u24, distance m u24, small calories u24]`, big-endian.
    static func sportTick(_ p: [UInt8]) -> RingSportTick? {
        guard p.count >= 14, let state = RingSportTick.State(rawValue: Int(p[1])) else { return nil }
        func be(_ at: Int, _ count: Int) -> Int { (0..<count).reduce(0) { ($0 << 8) | Int(p[at + $1]) } }
        let hr = Int(p[4])
        return RingSportTick(sport: Int(p[0]), state: state, elapsed: be(2, 2),
                             heartRate: (40...220).contains(hr) ? hr : nil, steps: be(5, 3),
                             distanceMeters: be(8, 3), kilocalories: Double(be(11, 3)) / 1000)
    }
}

extension RingRequest {
    static func phoneSport(_ command: RingSportCommand, sport: Int) -> RingRequest {
        .command(RingOp.phoneSport, [command.rawValue, UInt8(clamping: sport)])
    }
}

/// A workout as the summary shows it and Jarvis Health keeps it.
struct RingWorkout: Codable, Equatable, Identifiable {
    var sport: Int
    var sportName: String
    var start: Date
    var end: Date
    /// Seconds the ring counted as active (pauses excluded).
    var activeSeconds: Int
    var steps: Int
    var distanceMeters: Double
    /// Where the distance came from: "gps" outdoors, else "ring".
    var distanceSource: String
    var kilocalories: Double
    var heartRateAverage: Int?
    var heartRateMax: Int?
    /// Heart rate every 5 seconds (0 where there was no reading).
    var heartRates: [Int]
    /// Seconds in zones 1–5.
    var zoneSeconds: [Int]

    var id: String { ISO8601DateFormatter().string(from: start) }

    enum CodingKeys: String, CodingKey {
        case sport, start, end, steps, kilocalories
        case sportName = "sport_name"
        case activeSeconds = "active_seconds"
        case distanceMeters = "distance_meters"
        case distanceSource = "distance_source"
        case heartRateAverage = "hr_avg"
        case heartRateMax = "hr_max"
        case heartRates = "heart_rates"
        case zoneSeconds = "zone_seconds"
    }
}

/// Saves finished workouts to Jarvis Health, keeping any the server could
/// not take and sending them with the next one (or the next Health refresh).
@MainActor
enum WorkoutUploader {
    private static let key = "jc.workouts.pending"

    struct Pending: Codable {
        var workout: RingWorkout
        var deviceID: String?
    }

    static func save(_ workout: RingWorkout, deviceID: String?) async {
        var queue = pending()
        queue.removeAll { $0.workout.start == workout.start }
        queue.append(Pending(workout: workout, deviceID: deviceID))
        store(queue)
        await flush()
    }

    /// Sends what is waiting; what fails stays for next time.
    static func flush(client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) async {
        var left: [Pending] = []
        for item in pending() {
            do { try await client.pushWorkout(item.workout, deviceID: item.deviceID) } catch { left.append(item) }
        }
        store(left)
    }

    static func pending() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private static func store(_ queue: [Pending]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: key)
    }
}
