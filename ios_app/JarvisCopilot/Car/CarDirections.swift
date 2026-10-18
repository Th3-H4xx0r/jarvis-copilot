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
    /// Something was handed to the car: the voice conversation ends after its reply.
    var onQueued: (() -> Void)?
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
        onQueued?()
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

/// What Jarvis does on the phone that iOS only allows in front — a map link, a
/// call, opening an app — goes to the car's screen while CarPlay is up (Apple's way
/// for a CarPlay voice app). With the phone locked each was otherwise a "tap to
/// run" notification: unlock, tap, Jarvis, then the thing he asked for.
@MainActor
enum CarLinks {
    /// Apple Maps, Google Maps and Waze links, web or app.
    static func isMap(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["maps", "comgooglemaps", "comgooglemapsurl", "waze"].contains(scheme) { return true }
        guard scheme == "http" || scheme == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        if ["maps.apple.com", "maps.google.com", "maps.app.goo.gl", "waze.com", "www.waze.com"].contains(host) {
            return true
        }
        return ["google.com", "www.google.com"].contains(host) && url.path.hasPrefix("/maps")
    }

    /// Run ahead of the phone's skills (`InvokeRunner`'s native route): nil steps
    /// aside. The map opens when Jarvis has finished saying where it's going.
    static func route(_ skill: String, _ args: [String: Any]) async throws -> [String: Any]? {
        try await route(skill, args, carScreen: { CarScreen.isConnected },
                        directions: { try await CarDirections.start(to: $0, presence: .shared) },
                        queue: { CarHandoff.shared.queue($0) },
                        openNow: { CarScreen.open($0) { _ in } })
    }

    /// A link's own text address opened the maps app with no route (an empty
    /// `saddr`, a web link handed to the app): its destination takes
    /// `car_directions`' path instead — found near him, opened by coordinates in
    /// his maps app. The link itself opens only when it names no place, or the
    /// place can't be found.
    static func route(_ skill: String, _ args: [String: Any],
                      carScreen: () -> Bool,
                      directions: (String) async throws -> [String: Any],
                      queue: (URL) -> Void,
                      openNow: (URL) -> Void = { _ in }) async throws -> [String: Any]? {
        guard carScreen() else { return nil }
        switch skill {
        case "make_call":
            // A `tel:` link opened on the car's screen places the call through CarPlay,
            // once Jarvis has said who it's calling — Stop before then cancels it.
            let number = ContactLookup.cleanNumber(SkillArgs.string(args, "number"))
            guard number.contains(where: \.isNumber), let url = URL(string: "tel:\(number)") else { return nil }
            queue(url)
            return ["launched": true, "note": "Calling from the car when you finish speaking."]
        case "send_sms":
            // iOS never sends a text silently (the Mac sends it as him when it can):
            // on CarPlay the message opens filled in on the car's screen to confirm.
            // A photo attached keeps the phone's composer.
            let number = ContactLookup.cleanNumber(SkillArgs.string(args, "number"))
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?#")
            guard number.contains(where: \.isNumber), SkillArgs.string(args, "image_path").isEmpty,
                  SkillArgs.string(args, "image_base64").isEmpty,
                  let body = SkillArgs.string(args, "message").addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "sms:\(number)&body=\(body)") else { return nil }
            queue(url)
            return ["launched": true, "note": "The message opens filled in on the car's screen; he confirms Send there."]
        case "open_app":
            guard let url = carApp(args) else { return nil }
            queue(url)
            return ["launched": true, "note": "It opens on the car's screen when you finish speaking."]
        default:
            break
        }
        guard skill == "open_url", let url = URL(string: SkillArgs.string(args, "url")) else { return nil }
        if isCarAppLink(url) {
            // A song, a podcast: `now` (the server playing it) opens it on the car's
            // screen at once — the app is the answer, and Spotify only plays what
            // it's opened on. Otherwise after the reply, like the rest.
            if (args["now"] as? Bool) == true { openNow(url) } else { queue(url) }
            return ["launched": true, "note": "Opening it on the car's screen."]
        }
        guard isMap(url) else { return nil }
        let note = "Opening on the car's screen when you finish speaking."
        if let destination = destination(in: url), var route = try? await directions(destination) {
            route["launched"] = true
            route["note"] = note
            return route
        }
        queue(url)
        return ["launched": true, "note": note]
    }

    /// Apps with a screen in CarPlay, by the names Jarvis uses, and the link that
    /// opens each. Anything else stays the phone's (it can't show on the car).
    static let carApps: [String: String] = [
        "spotify": "spotify://", "music": "music://", "apple music": "music://",
        "podcasts": "podcasts://", "apple podcasts": "podcasts://", "audible": "audible://",
        "pandora": "pandora://", "youtube music": "youtubemusic://", "waze": "waze://",
        "maps": "maps://", "apple maps": "maps://", "google maps": "comgooglemaps://",
        "whatsapp": "whatsapp://", "calendar": "calshow://",
    ]

    /// A link into one of the CarPlay apps that isn't a map (`spotify:track:…`).
    static func isCarAppLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !isMap(url) else { return false }
        return Set(carApps.values.compactMap { URL(string: $0)?.scheme }).contains(scheme)
    }

    /// The CarPlay app `open_app` asks for: by name, or a bare link to one of them
    /// (`spotify://`) — never a link with a payload (open_app's own gate).
    static func carApp(_ args: [String: Any]) -> URL? {
        let explicit = SkillArgs.string(args, "scheme_url").trimmingCharacters(in: .whitespaces).lowercased()
        if !explicit.isEmpty {
            return Set(carApps.values).contains(explicit) ? URL(string: explicit) : nil
        }
        let name = SkillArgs.text(args["app"] ?? args["name"]).trimmingCharacters(in: .whitespaces).lowercased()
        return carApps[name].flatMap(URL.init(string:))
    }

    /// Where a map link goes, as text to search for: `daddr` (Apple, Google's
    /// app), `destination` (Google's web), `q` / `query` (a search), or the place
    /// in a Google path (`/maps/dir/<from>/<to>`, `/maps/place/<name>`,
    /// `/maps/search/<q>`). Nil for a link that names none (a short link).
    static func destination(in url: URL) -> String? {
        func text(_ raw: String?) -> String? {
            let value = (raw ?? "").replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in ["daddr", "destination", "q", "query"] {
            if let value = text(items.first(where: { $0.name == name })?.value) { return value }
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        for marker in ["place", "search"] {
            if let i = parts.firstIndex(of: marker), i + 1 < parts.count { return text(parts[i + 1]) }
        }
        if let i = parts.firstIndex(of: "dir") {
            return text(parts[(i + 1)...].last { !$0.hasPrefix("@") && !$0.hasPrefix("data=") })
        }
        return nil
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
