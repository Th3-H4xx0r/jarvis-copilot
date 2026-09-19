import CoreLocation
import Foundation

/// One accepted GPS fix of a workout's route. Stored as a compact array —
/// `[t, lat, lon, ele, hr, speed]` — because a long hike has thousands.
struct RoutePoint: Equatable {
    /// Seconds since the route's start, on the wall clock (pauses included).
    var t: Double
    var lat: Double
    var lon: Double
    /// Metres above sea level: the barometer's when it had one, else GPS.
    var ele: Double?
    /// The wearable's heart rate at that moment, when it had one.
    var hr: Int?
    /// GPS speed, m/s, when the fix carried a valid one.
    var speed: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension RoutePoint: Codable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = try c.decode(Double.self)
        lat = try c.decode(Double.self)
        lon = try c.decode(Double.self)
        ele = c.isAtEnd ? nil : try c.decodeIfPresent(Double.self)
        hr = c.isAtEnd ? nil : try c.decodeIfPresent(Int.self)
        speed = c.isAtEnd ? nil : try c.decodeIfPresent(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        func round(_ value: Double, _ places: Double) -> Double { (value * places).rounded() / places }
        try c.encode(round(t, 10))
        try c.encode(round(lat, 1_000_000))
        try c.encode(round(lon, 1_000_000))
        if let ele { try c.encode(round(ele, 10)) } else { try c.encodeNil() }
        if let hr { try c.encode(hr) } else { try c.encodeNil() }
        if let speed { try c.encode(round(speed, 100)) } else { try c.encodeNil() }
    }
}

/// Where a workout went: one segment per stretch between pauses.
struct WorkoutRoute: Codable, Equatable {
    var version = 1
    var start: Date
    var segments: [[RoutePoint]]
    /// "barometer", "gps" or "none": how far the elevation can be trusted.
    var elevationSource: String

    var points: [RoutePoint] { segments.flatMap { $0 } }
    var isEmpty: Bool { segments.allSatisfy { $0.count < 2 } }

    enum CodingKeys: String, CodingKey {
        case version, start, segments
        case elevationSource = "elevation_source"
    }
}

/// What a workout's list row, Apple Health and the day need of its route,
/// carried in the workout itself (the route is its own, larger document).
struct RouteSummary: Codable, Equatable {
    var distanceMeters: Double
    var movingSeconds: Int
    var gainMeters: Double?
    var lossMeters: Double?
    var minMeters: Double?
    var maxMeters: Double?
    /// m/s, over the fastest ten seconds.
    var maxSpeed: Double?
    /// The route's outline as a Google-encoded polyline of at most 120 points.
    var preview: String
    /// [south, west, north, east].
    var bounds: [Double]

    enum CodingKeys: String, CodingKey {
        case preview, bounds
        case distanceMeters = "distance_m"
        case movingSeconds = "moving_s"
        case gainMeters = "gain_m"
        case lossMeters = "loss_m"
        case minMeters = "min_m"
        case maxMeters = "max_m"
        case maxSpeed = "max_speed"
    }
}

/// Kilometres or miles, and with them metres or feet for elevation.
enum DistanceUnit: String, Codable, CaseIterable, Identifiable {
    case km, mi

    var id: String { rawValue }
    static let feetPerMeter = 3.280839895
    private static let key = "jc.distance.unit"

    /// What the phone's region uses.
    static var regional: DistanceUnit { Locale.current.measurementSystem == .us ? .mi : .km }

    /// The person's choice, else the region's.
    static var current: DistanceUnit {
        get { UserDefaults.standard.string(forKey: key).flatMap(DistanceUnit.init(rawValue:)) ?? regional }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Metres in one of this unit.
    var meters: Double { self == .km ? 1000 : 1609.344 }
    var symbol: String { rawValue }
    var elevationSymbol: String { self == .km ? "m" : "ft" }
    var speedSymbol: String { self == .km ? "km/h" : "mph" }

    /// "3.42" — two decimals, in this unit.
    func distance(_ meters: Double) -> String { String(format: "%.2f", meters / self.meters) }

    /// "8:12" per unit, from seconds per metre; "--" when there is no pace.
    func pace(secondsPerMeter: Double?) -> String {
        guard let secondsPerMeter, secondsPerMeter.isFinite, secondsPerMeter > 0 else { return "--" }
        let seconds = Int((secondsPerMeter * meters).rounded())
        guard seconds < 100 * 60 else { return "--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Whole metres or feet.
    func elevation(_ meters: Double) -> String {
        Int((self == .km ? meters : meters * Self.feetPerMeter).rounded()).formatted()
    }

    /// "12.4" km/h or mph.
    func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.1f", metersPerSecond * 3600 / meters)
    }
}

/// How routes are drawn: Apple's map, satellite with labels, or contours.
enum MapStyle: String, Codable, CaseIterable, Identifiable {
    case standard, satellite, topo

    var id: String { rawValue }
    private static let key = "jc.map.style"

    static var current: MapStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(MapStyle.init(rawValue:)) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .topo: return "Topo"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas.fill"
        case .topo: return "mountain.2"
        }
    }
}
