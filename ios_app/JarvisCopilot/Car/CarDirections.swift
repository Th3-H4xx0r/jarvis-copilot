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

    /// MapKit's best match — or, for a chain ("Starbucks", three nearby), its nearest
    /// branch. Never a nearer place that only partly matches what he named.
    static func pick(_ places: [CarPlace]) -> CarPlace? {
        guard let top = places.first else { return nil }
        return places.filter { $0.name.caseInsensitiveCompare(top.name) == .orderedSame }
            .min { $0.meters < $1.meters }
    }
}

/// Jarvis's car screen, for opening other apps on it (a phone-side open needs the phone unlocked).
@MainActor
enum CarScreen {
    static weak var scene: CPTemplateApplicationScene?

    static var isConnected: Bool { scene != nil }

    /// `done(false)`: no car screen, or it couldn't open the URL.
    static func open(_ url: URL, done: @escaping (Bool) -> Void) {
        guard let scene else { done(false); return }
        scene.open(url, options: nil) { ok in Task { @MainActor in done(ok) } }
    }
}

/// Opens the map once Jarvis has said where it's going: Maps speaking over the
/// "Starting directions to …" line would drown it. Stop during the line cancels.
@MainActor
final class CarHandoff {
    static let shared = CarHandoff(open: { CarScreen.open($0, done: $1) },
                                   sessionActive: { VoiceStore.shared.isActive })

    private let cap: TimeInterval
    private let open: (URL, @escaping (Bool) -> Void) -> Void
    private let sessionActive: () -> Bool
    private var pending: (url: URL, fallback: URL?)?
    private var capTask: Task<Void, Never>?

    /// `cap`: open anyway this long after the tool returned — a turn that never
    /// finishes can't swallow the directions.
    init(cap: TimeInterval = 15, open: @escaping (URL, @escaping (Bool) -> Void) -> Void,
         sessionActive: @escaping () -> Bool) {
        self.cap = cap
        self.open = open
        self.sessionActive = sessionActive
    }

    /// No voice turn running (asked in chat): open now. Otherwise wait for the reply.
    /// `fallback` (Apple Maps) opens if the car screen won't open `url`: the
    /// directions have been announced, so they must open somewhere.
    func queue(_ url: URL, fallback: URL? = nil) {
        pending = (url, fallback)
        guard sessionActive() else { release(); return }
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
        guard let (url, fallback) = pending else { return }
        stopped()
        open(url) { [open] ok in
            guard !ok else { return }
            guard let fallback else {
                JcLog.dropped(JcLog.services, "open directions on the car screen", URLError(.unsupportedURL))
                return
            }
            open(fallback) { ok in
                if !ok { JcLog.dropped(JcLog.services, "open Apple Maps on the car screen", URLError(.unsupportedURL)) }
            }
        }
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
        guard let place = CarPlace.pick(try await search(destination, near: fix)) else {
            throw DeviceError.badArgument("Couldn't find \(destination) near you")
        }
        var app = CarMapsApp.current(preferences)
        var note: String?
        let wanted = app.url(latitude: place.latitude, longitude: place.longitude)
        if app != .apple, !UIApplication.shared.canOpenURL(wanted) {
            note = "\(app.title) isn't installed — using Apple Maps"
            app = .apple
        }
        handoff.queue(app.url(latitude: place.latitude, longitude: place.longitude),
                      fallback: app == .apple ? nil : CarMapsApp.apple.url(latitude: place.latitude,
                                                                          longitude: place.longitude))
        var out: [String: Any] = ["ok": true, "place": place.name, "street": place.street,
                                  "address": place.address, "distance_miles": place.miles, "app": app.title]
        if let note { out["note"] = note }
        return out
    }

    /// MapKit says "no results" with an error; any other error is a failed search.
    static func isNothingFound(_ error: Error) -> Bool {
        (error as? MKError)?.code == .placemarkNotFound
    }

    /// MapKit's natural-language search around him (30 km), in its own ranking.
    private static func search(_ query: String, near fix: LocationFix) async throws -> [CarPlace] {
        let here = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000,
                                            longitudinalMeters: 30_000)
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            if isNothingFound(error) { return [] }
            throw DeviceError.badArgument("Map search failed (\(error.localizedDescription)) — try again")
        }
        return items.map { item in
            let at = item.placemark.coordinate
            return CarPlace(name: item.name ?? query, street: item.placemark.thoroughfare ?? "",
                            address: item.placemark.title ?? "", latitude: at.latitude, longitude: at.longitude,
                            meters: here.distance(from: CLLocation(latitude: at.latitude, longitude: at.longitude)))
        }
    }
}
