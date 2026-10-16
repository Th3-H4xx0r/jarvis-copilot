import CarPlay
import CoreLocation
import MapKit
import UIKit

/// The app turn-by-turn directions open in (Settings → CarPlay). Google Maps unless he picks another.
enum CarMapsApp: String, CaseIterable, Identifiable {
    case google, apple, waze

    static let key = "jc.car.directions_app"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google Maps"
        case .apple: return "Apple Maps"
        case .waze: return "Waze"
        }
    }

    static func current(_ preferences: KeyValueStore = UserDefaults.standard) -> CarMapsApp {
        preferences.string(key).flatMap(CarMapsApp.init(rawValue:)) ?? .google
    }

    /// Driving directions to a coordinate. Waze starts guidance on its own; the other two
    /// may stop at the route with a Start button (fine, his call).
    func url(latitude: Double, longitude: Double) -> URL {
        let to = String(format: "%.6f,%.6f", latitude, longitude)
        switch self {
        case .google: return URL(string: "comgooglemaps://?daddr=\(to)&directionsmode=driving")!
        case .apple: return URL(string: "maps://?daddr=\(to)&dirflg=d")!
        case .waze: return URL(string: "waze://?ll=\(to)&navigate=yes")!
        }
    }
}

/// A search result, with how far it is from him.
struct CarPlace: Equatable {
    let name: String
    let street: String
    let address: String
    let latitude: Double
    let longitude: Double
    let meters: Double

    var miles: Double { (meters / 1609.344 * 10).rounded() / 10 }

    /// "Take me to Starbucks" with three nearby: the closest.
    static func closest(_ places: [CarPlace]) -> CarPlace? { places.min { $0.meters < $1.meters } }
}

/// Jarvis's car screen, for opening other apps on it (a phone-side open needs the phone unlocked).
@MainActor
enum CarScreen {
    static weak var scene: CPTemplateApplicationScene?

    static var isConnected: Bool { scene != nil }

    static func open(_ url: URL) {
        scene?.open(url, options: nil) { ok in
            if !ok { JcLog.dropped(JcLog.services, "open on the car screen", URLError(.unsupportedURL)) }
        }
    }
}

/// Opens the map once Jarvis has said where it's going: Maps speaking over the
/// "Starting directions to …" line would drown it. Stop during the line cancels.
@MainActor
final class CarHandoff {
    static let shared = CarHandoff(open: { CarScreen.open($0) }, sessionActive: { VoiceStore.shared.isActive })

    private let cap: TimeInterval
    private let open: (URL) -> Void
    private let sessionActive: () -> Bool
    private var pending: URL?
    private var capTask: Task<Void, Never>?

    /// `cap`: open anyway this long after the tool returned — a turn that never
    /// finishes can't swallow the directions.
    init(cap: TimeInterval = 15, open: @escaping (URL) -> Void, sessionActive: @escaping () -> Bool) {
        self.cap = cap
        self.open = open
        self.sessionActive = sessionActive
    }

    /// No voice turn running (asked in chat): open now. Otherwise wait for the reply.
    func queue(_ url: URL) {
        guard sessionActive() else { open(url); return }
        pending = url
        capTask?.cancel()
        let cap = cap
        capTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// The reply finished playing.
    func turnFinished() { release() }

    /// Stop (the Talk widget's second tap, End): no directions.
    func stopped() {
        pending = nil
        capTask?.cancel()
        capTask = nil
    }

    private func release() {
        guard let url = pending else { return }
        stopped()
        open(url)
    }
}

/// `car_directions`: the closest match near him, opened in his maps app on the car screen.
@MainActor
enum CarDirections {
    static func start(to destination: String,
                      presence: CarPresence,
                      locator: LocationFixing = DefaultLocationFixer(),
                      handoff: CarHandoff = .shared,
                      preferences: KeyValueStore = UserDefaults.standard) async throws -> [String: Any] {
        guard CarScreen.isConnected else {
            throw DeviceError.badArgument(presence.inCar
                ? "Jarvis isn't open on the CarPlay screen — tap the Jarvis icon in CarPlay once, then ask again"
                : "CarPlay isn't connected — directions open on the car's screen while driving")
        }
        let fix = try await locator.oneShot(timeout: 6)
        guard let place = CarPlace.closest(await search(destination, near: fix)) else {
            throw DeviceError.badArgument("Couldn't find \(destination) near you")
        }
        var app = CarMapsApp.current(preferences)
        var note: String?
        let wanted = app.url(latitude: place.latitude, longitude: place.longitude)
        if app != .apple, !UIApplication.shared.canOpenURL(wanted) {
            note = "\(app.title) isn't installed — using Apple Maps"
            app = .apple
        }
        handoff.queue(app.url(latitude: place.latitude, longitude: place.longitude))
        var out: [String: Any] = ["ok": true, "place": place.name, "street": place.street,
                                  "address": place.address, "distance_miles": place.miles, "app": app.title]
        if let note { out["note"] = note }
        return out
    }

    /// MapKit's natural-language search around him (30 km), nearest first by the caller.
    private static func search(_ query: String, near fix: LocationFix) async -> [CarPlace] {
        let here = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000,
                                            longitudinalMeters: 30_000)
        // No results is an error from MapKit; either way, nothing found.
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return [] }
        return items.map { item in
            let at = item.placemark.coordinate
            return CarPlace(name: item.name ?? query, street: item.placemark.thoroughfare ?? "",
                            address: item.placemark.title ?? "", latitude: at.latitude, longitude: at.longitude,
                            meters: here.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)))
        }
    }
}
