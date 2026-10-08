import Foundation
import simd

/// Where the lamps are in the car, and which controller drives each — all data, in
/// `Lights/CarLights.json`, so moving a lamp is a one-line edit. Coordinates are the Camry
/// model's: metres, +X driver side (left), +Y up from the ground, +Z forward.
struct CarLightLayout: Codable, Equatable {
    struct Lamp: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        /// "main" = the first controller paired; otherwise a controller's name or id.
        var controller: String
        /// A point lamp…
        var at: [Double]?
        /// …or a strip from one end to the other.
        var from: [Double]?
        var to: [Double]?

        enum Shape: Equatable {
            case point(SIMD3<Float>)
            case strip(SIMD3<Float>, SIMD3<Float>)
        }

        var shape: Shape? {
            func vector(_ v: [Double]?) -> SIMD3<Float>? {
                guard let v, v.count == 3, v.allSatisfy(\.isFinite) else { return nil }
                return SIMD3(Float(v[0]), Float(v[1]), Float(v[2]))
            }
            if let p = vector(at) { return .point(p) }
            if let a = vector(from), let b = vector(to) { return .strip(a, b) }
            return nil
        }

        /// The middle of the lamp, for labels and taps.
        var center: SIMD3<Float>? {
            switch shape {
            case .point(let p): return p
            case .strip(let a, let b): return (a + b) / 2
            case nil: return nil
            }
        }
    }

    enum LayoutError: LocalizedError {
        case badLamp(String)
        case duplicate(String)
        var errorDescription: String? {
            switch self {
            case .badLamp(let id): return "lamp '\(id)' needs 'at' or 'from' + 'to' with three numbers each"
            case .duplicate(let id): return "two lamps are called '\(id)'"
            }
        }
    }

    var version: Int
    var lamps: [Lamp]

    static func decode(_ data: Data) throws -> CarLightLayout {
        let layout = try JSONDecoder().decode(CarLightLayout.self, from: data)
        var seen = Set<String>()
        for lamp in layout.lamps {
            guard lamp.shape != nil else { throw LayoutError.badLamp(lamp.id) }
            guard seen.insert(lamp.id).inserted else { throw LayoutError.duplicate(lamp.id) }
        }
        return layout
    }

    /// The layout shipped with the app; empty if the file is missing or broken.
    static let bundled: CarLightLayout = Bundle.main.url(forResource: "CarLights", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? decode($0) } ?? CarLightLayout(version: 1, lamps: [])

    /// The controller a lamp's "controller" field names, among those paired.
    static func controllerID(for lamp: Lamp, in controllers: [CarLightsController]) -> String? {
        if lamp.controller == "main" { return controllers.first?.id }
        return controllers.first { $0.id == lamp.controller }?.id
            ?? controllers.first { $0.name.caseInsensitiveCompare(lamp.controller) == .orderedSame }?.id
    }

    /// The lamps a controller drives — they always show the same thing.
    func lamps(on controllerID: String, controllers: [CarLightsController]) -> [Lamp] {
        lamps.filter { Self.controllerID(for: $0, in: controllers) == controllerID }
    }
}
