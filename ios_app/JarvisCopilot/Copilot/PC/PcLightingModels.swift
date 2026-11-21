import Foundation

/// The PC's lit parts, in the order every platform uses (server: api/pc_lighting_store.PARTS).
enum PcPart: String, CaseIterable, Codable, Identifiable, Hashable {
    case top, rear, bottom, cooler, strip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "Top fans"
        case .rear: "Rear fans"
        case .bottom: "Bottom fans"
        case .cooler: "Cooler"
        case .strip: "Strip"
        }
    }

    /// How many fans (or rings) the part has on this PC.
    var count: Int {
        switch self {
        case .top, .rear: 2
        case .bottom: 3
        case .cooler, .strip: 1
        }
    }
}

/// Jarvis's own effects (desktop_client/jc_client/pc_lighting/effects.py — same maths in PcEffects).
enum PcEffect: String, CaseIterable, Identifiable {
    case still = "static", breathing, rainbow, spectrum, comet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .still: "Static"
        case .breathing: "Breathing"
        case .rainbow: "Rainbow"
        case .spectrum: "Spectrum"
        case .comet: "Comet"
        }
    }

    var animated: Bool { self != .still }
}

/// One LED of the model: which fan/ring of which part, and its position along it.
struct PcLedKey: Hashable {
    let part: PcPart
    let index: Int
    let led: Int
}

struct PcPartLight: Codable, Hashable {
    var effect: String
    var color: String
    var speed: Int

    static let white = PcPartLight(effect: "static", color: "#ffffff", speed: 5)
}

struct PcLightingState: Codable, Hashable {
    var on: Bool
    var brightness: Int
    var t0: Double
    var frozenAt: Double?
    var stillInGames: Bool?
    var rev: Int?
    var parts: [String: PcPartLight]

    func light(_ part: PcPart) -> PcPartLight { parts[part.rawValue] ?? .white }
}

struct PcZone: Codable, Equatable {
    var controller: Int
    var zone: Int
    var leds: Int
    /// The connector's colour order ("grb" when red shows green); nil = rgb.
    var order: String? = nil
}

struct PcSegment: Codable, Equatable {
    var part: String
    var index: Int?
    var controller: Int
    var zone: Int
    var start: Int
    var count: Int
    var ringStartDeg: Double?
    var clockwise: Bool?
    var from: String?
    var also: [String]?
}

struct PcLedMap: Codable, Equatable {
    var version: Int = 1
    var rev: Int?
    var zones: [PcZone] = []
    var segments: [PcSegment] = []

    var isMapped: Bool { !segments.isEmpty }
}

struct PcLightLook: Codable, Equatable, Identifiable {
    var name: String
    var parts: [String: PcPartLight]
    var brightness: Int

    var id: String { name }
}

struct PcSetupStep: Codable, Equatable, Identifiable {
    var id: String
    var state: String
    var detail: String
    var stillInGames: Bool?
}

struct PcZoneInfo: Codable, Equatable {
    var index: Int
    var name: String
    var leds: Int
    var resizable: Bool?
    /// The most LEDs OpenRGB allows on this connector.
    var max: Int?
}

struct PcController: Codable, Equatable {
    var index: Int
    var name: String
    var location: String?
    var zones: [PcZoneInfo]
}

/// What the Jarvis app on the PC read about its hardware (desktop_client/jc_client/pc_specs.py).
struct PcSpecs: Codable, Equatable {
    struct Cpu: Codable, Equatable { var name: String?; var cores: Int?; var threads: Int?; var maxMhz: Int? }
    struct Gpu: Codable, Equatable { var name: String?; var vramMb: Int?; var driver: String? }
    struct Board: Codable, Equatable { var maker: String?; var product: String?; var bios: String? }
    struct Module: Codable, Equatable { var maker: String?; var part: String?; var sizeMb: Int?; var mhz: Int? }
    struct Memory: Codable, Equatable { var totalMb: Int?; var modules: [Module]? }
    struct Drive: Codable, Equatable { var model: String?; var sizeGb: Int?; var kind: String? }
    struct Display: Codable, Equatable { var name: String?; var width: Int?; var height: Int?; var hz: Int? }
    struct Os: Codable, Equatable { var name: String?; var version: String?; var build: String? }
    struct System: Codable, Equatable { var maker: String?; var model: String? }

    var readAt: Double?
    var cpu: Cpu?
    var gpus: [Gpu]?
    var board: Board?
    var memory: Memory?
    var storage: [Drive]?
    var displays: [Display]?
    var os: Os?
    var system: System?
}

/// The server's JSON is snake_case; everything here is decoded from the parsed object.
enum PcCodec {
    static func decode<T: Decodable>(_ type: T.Type, _ object: Any?) -> T? {
        guard let object, !(object is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    static func object<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
        return obj
    }
}
