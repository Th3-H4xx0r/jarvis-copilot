import Combine
import Foundation
import simd

/// Where the lamps are in the car — only where; they all show the same thing (the lights have no
/// lamp or zone address). The default ships in `Lights/CarLights.json`; the Arrange lamps editor
/// saves the user's own (`CarLightLayoutStore`). Coordinates are the Camry model's: metres, +X
/// driver side (left), +Y up from the ground, +Z forward.
struct CarLightLayout: Codable, Equatable {
    struct Lamp: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        /// A spot…
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

        /// The middle of the lamp, for picking it.
        var center: SIMD3<Float>? {
            switch shape {
            case .point(let p): return p
            case .strip(let a, let b): return (a + b) / 2
            case nil: return nil
            }
        }

        static func spot(id: String, name: String, at p: SIMD3<Float>) -> Lamp {
            Lamp(id: id, name: name, at: Self.array(p))
        }

        static func strip(id: String, name: String, from a: SIMD3<Float>, to b: SIMD3<Float>) -> Lamp {
            Lamp(id: id, name: name, from: Self.array(a), to: Self.array(b))
        }

        /// The same lamp, slid by `delta`.
        func moved(by delta: SIMD3<Float>) -> Lamp {
            var lamp = self
            switch shape {
            case .point(let p): lamp.at = Self.array(p + delta)
            case .strip(let a, let b): lamp.from = Self.array(a + delta); lamp.to = Self.array(b + delta)
            case nil: break
            }
            return lamp
        }

        private static func array(_ v: SIMD3<Float>) -> [Double] {
            [v.x, v.y, v.z].map { (Double($0) * 1000).rounded() / 1000 }   // millimetres are plenty
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
}

/// The lamp layout the app shows: the user's own once they've arranged lamps, else the shipped one.
@MainActor
final class CarLightLayoutStore: ObservableObject {
    static let shared = CarLightLayoutStore()

    @Published private(set) var layout: CarLightLayout
    /// Whether the user has their own layout (Reset goes back to the shipped one).
    @Published private(set) var customised: Bool

    private let file: URL
    private let fallback: CarLightLayout

    init(file: URL = CarLightLayoutStore.defaultFile, fallback: CarLightLayout = .bundled) {
        self.file = file
        self.fallback = fallback
        if let data = try? Data(contentsOf: file), let saved = try? CarLightLayout.decode(data) {
            layout = saved
            customised = true
        } else {
            layout = fallback
            customised = false
        }
    }

    nonisolated static var defaultFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("CarLights.json")
    }

    /// Adds a spot or strip; returns its id.
    @discardableResult
    func add(_ shape: CarLightLayout.Lamp.Shape, name: String? = nil) -> String {
        let id = "lamp-" + UUID().uuidString.prefix(6).lowercased()
        let label = name ?? "Lamp \(layout.lamps.count + 1)"
        switch shape {
        case .point(let p): layout.lamps.append(.spot(id: id, name: label, at: p))
        case .strip(let a, let b): layout.lamps.append(.strip(id: id, name: label, from: a, to: b))
        }
        save()
        return id
    }

    func remove(_ id: String) {
        layout.lamps.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = layout.lamps.firstIndex(where: { $0.id == id }) else { return }
        layout.lamps[i].name = String(trimmed.prefix(40))
        save()
    }

    /// Moves a lamp; `persist` false while a finger is still dragging it.
    func move(_ id: String, by delta: SIMD3<Float>, persist: Bool = true) {
        guard let i = layout.lamps.firstIndex(where: { $0.id == id }) else { return }
        layout.lamps[i] = layout.lamps[i].moved(by: delta)
        if persist { save() }
    }

    func commit() { save() }

    func reset() {
        try? FileManager.default.removeItem(at: file)
        layout = fallback
        customised = false
    }

    private func save() {
        customised = true
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layout).write(to: file, options: .atomic)
        } catch {
            JcLog.devices.notice("lights: couldn't save the lamp layout — \(error.localizedDescription, privacy: .public)")
        }
    }
}
