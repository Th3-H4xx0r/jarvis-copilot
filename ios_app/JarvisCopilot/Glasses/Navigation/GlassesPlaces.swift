import Foundation
import CoreLocation

/// A place the GO3's Navigation app can take you to. `number` is the stable index the
/// lens echoes back for "other" places (home and work are found by kind).
struct GlassesPlace: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case home, work, other }
    var id = UUID()
    var kind: Kind
    var number: Int64
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    /// Lens address type: 0 home, 1 work, 2 other.
    var lensType: Int { kind == .home ? 0 : kind == .work ? 1 : 2 }
}

/// The saved places, kept on this phone (the lens never gets coordinates, only names).
@MainActor final class GlassesPlaces: ObservableObject {
    static let shared = GlassesPlaces()
    static let key = "glasses.navigation.places"
    private let defaults: UserDefaults
    @Published private(set) var places: [GlassesPlace] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([GlassesPlace].self, from: data) { places = saved }
    }

    /// Save a place. Setting a new home or work replaces the old one.
    @discardableResult
    func add(kind: GlassesPlace.Kind, name: String, detail: String, coordinate: CLLocationCoordinate2D) -> GlassesPlace {
        if kind != .other { places.removeAll { $0.kind == kind } }
        let number = (places.map(\.number).max() ?? 0) + 1
        let place = GlassesPlace(kind: kind, number: number, name: name, detail: detail, latitude: coordinate.latitude, longitude: coordinate.longitude)
        places.append(place)
        save()
        return place
    }
    func remove(_ place: GlassesPlace) { places.removeAll { $0.id == place.id }; save() }
    func setKind(_ kind: GlassesPlace.Kind, for place: GlassesPlace) {
        if kind != .other { for i in places.indices where places[i].kind == kind { places[i].kind = .other } }
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i].kind = kind }
        save()
    }
    private func save() { if let data = try? JSONEncoder().encode(places) { defaults.set(data, forKey: Self.key) } }

    /// The lens list, in the official order: home, work, then the others.
    nonisolated static func lensEntries(_ places: [GlassesPlace]) -> [InmoNavigationWire.Address] {
        places.sorted { $0.lensType < $1.lensType }
            .map { .init(index: $0.kind == .other ? $0.number : 0, type: $0.lensType, name: $0.name, detail: $0.detail) }
    }
    /// The place the lens picked (type 0 home, 1 work, 2 other by index).
    nonisolated static func match(_ places: [GlassesPlace], type: Int, index: Int64) -> GlassesPlace? {
        switch type {
        case 0: return places.first { $0.kind == .home }
        case 1: return places.first { $0.kind == .work }
        default: return places.first { $0.kind == .other && $0.number == index }
        }
    }
}
