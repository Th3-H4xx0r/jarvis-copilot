import Foundation
import CoreLocation
import MapKit

/// Jarvis as the phone side of the GO3's Navigation app, the way the official app is
/// (inmo-re/notes/go3-navigation-flow.md): offer Navigation when the glasses ask which
/// modules the phone serves, send the saved places when Navigation opens on the lens,
/// plan cycling + walking with MapKit when one is picked, then stream turn, remaining
/// distance and a minimap once a second until arrival, re-planning when off route.
@MainActor final class GlassesNavigator: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GlassesNavigator()
    enum State: String { case idle, planning, choosing, guiding, arrived }
    @Published private(set) var state: State = .idle
    @Published private(set) var destinationName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var last: NavigationGuidance.Update?

    private let session = InmoSession.shared
    private let places = GlassesPlaces.shared
    private let manager = CLLocationManager()
    private var observer: UUID?
    private var destination: CLLocationCoordinate2D?
    private var plans: (cycling: MKRoute?, walking: MKRoute?) = (nil, nil)
    private var mode: MKDirectionsTransportType = .walking
    private var guidance: NavigationGuidance?
    private var countryCode: String { Locale.current.region?.identifier == "US" ? "USA" : "" }
    private var startedAt = Date()
    private var travelled = 0.0
    private var lastFix: CLLocation?
    private var heading = 0.0
    private var lastImageAt = Date.distantPast
    private var cardKey = ""
    private var cardStage = -1
    private var sentGuide: NavigationGuidance.Update?
    private var sentRemaining: NavigationGuidance.Update?
    private var offRouteFixes = 0
    private var replanning = false
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var sendChain: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        observer = session.addEventObserver { [weak self] event in self?.handle(event) }
    }

    func install(on device: InmoGo3Device) {
        device.featureHandlers["glasses_navigate"] = { [weak self] args in
            guard let self else { throw InmoProtocolError.cancelled }
            guard let query = (args["destination"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw DeviceError.badArgument("destination is required")
            }
            let walking = (args["mode"] as? String ?? "walk").lowercased().hasPrefix("walk")
            return try await self.navigate(to: query, walking: walking)
        }
        device.featureHandlers["glasses_navigate_stop"] = { [weak self] _ in
            self?.stop(fromLens: false)
            return ["state": "stopped"]
        }
    }

    // MARK: Glasses events

    private func handle(_ event: InmoEvent) {
        switch event {
        case .connectionChanged(let state):
            // The glasses ask which modules the phone serves (Message 35) while the link is
            // still authenticating, before anything can be written — so answer on ready too.
            if state == .ready { send(InmoNavigationWire.supportedModules([2])); note("offered Navigation on connect") }
            if state != .ready, self.state == .guiding || self.state == .choosing { end("glasses disconnected") }
        case let .message(type, fields, _):
            if type == 35, session.isReady { send(InmoNavigationWire.supportedModules([2])); note("offered Navigation") }
            if let open = InmoNavigationWire.appSwitch(fields) {
                if open { sendPlaces() } else if state != .idle { end("closed on the lens") }
            }
            switch InmoNavigationWire.incoming(fields) {
            case let .start(type, index)?: startFromLens(type: type, index: index)
            case let .selected(walking)?: choose(walking: walking)
            case nil: break
            }
        }
    }

    private func sendPlaces() {
        let entries = GlassesPlaces.lensEntries(places.places)
        send(InmoNavigationWire.addresses(entries))
        note("sent \(entries.count) places")
    }

    private func startFromLens(type: Int, index: Int64) {
        guard let place = GlassesPlaces.match(places.places, type: type, index: index) else {
            note("lens picked an unknown place type=\(type) index=\(index)")
            send(InmoNavigationWire.permission(false)); return
        }
        destinationName = place.name
        Task { await plan(to: place.coordinate) }
    }

    private func plan(to target: CLLocationCoordinate2D) async {
        state = .planning; destination = target; lastError = nil
        guard let here = await currentFix() else { return fail("No location — allow Jarvis location access (Always works best)") }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: target))
        async let bike = Self.route(from: here.coordinate, to: item, .cycling)
        async let walk = Self.route(from: here.coordinate, to: item, .walking)
        plans = await (bike, walk)
        guard plans.cycling != nil || plans.walking != nil else { return fail("Apple Maps found no walking or cycling route") }
        func plan(_ r: MKRoute?) -> InmoNavigationWire.Plan {
            r.map { .init(achievable: true, seconds: Int64($0.expectedTravelTime), meters: Int64($0.distance)) } ?? .init(achievable: false, seconds: 0, meters: 0)
        }
        send(InmoNavigationWire.routePlanning(cycling: plan(plans.cycling), walking: plan(plans.walking), countryCode: countryCode))
        state = .choosing
        note("planned bike=\(plans.cycling.map { Int($0.distance) } ?? -1)m walk=\(plans.walking.map { Int($0.distance) } ?? -1)m")
    }

    private func choose(walking: Bool) {
        guard let route = walking ? plans.walking : plans.cycling else { return fail("No \(walking ? "walking" : "cycling") route") }
        mode = walking ? .walking : .cycling
        startGuidance(route)
    }

    // MARK: Voice

    /// "Take me to …": find the place near you, save it for the lens list, and start
    /// guidance straight away (the phone-initiated start the official app also uses).
    func navigate(to query: String, walking: Bool) async throws -> [String: Any] {
        guard session.isReady else { throw DeviceError.notConnected }
        guard let here = await currentFix() else { throw DeviceError.badArgument("No location — allow Jarvis location access") }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
            throw DeviceError.badArgument("Couldn't find \(query) nearby")
        }
        let name = item.name ?? query
        let target = item.placemark.coordinate
        if !places.places.contains(where: { $0.name == name && NavigationGeo.distance($0.coordinate, target) < 50 }) {
            places.add(kind: .other, name: name, detail: item.placemark.title ?? "", coordinate: target)
        }
        return try await go(from: here, to: item, name: name, walking: walking)
    }

    /// Start guidance to a saved place from the phone (the Places page's Walk / Bike).
    @discardableResult
    func start(to place: GlassesPlace, walking: Bool) async throws -> [String: Any] {
        guard session.isReady else { throw DeviceError.notConnected }
        guard let here = await currentFix() else { throw DeviceError.badArgument("No location — allow Jarvis location access") }
        return try await go(from: here, to: MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate)), name: place.name, walking: walking)
    }

    /// The phone-initiated start the official app also uses: open Navigation on the
    /// lens and stream guidance straight away, without the lens's pick-a-place steps.
    private func go(from here: CLLocation, to item: MKMapItem, name: String, walking: Bool) async throws -> [String: Any] {
        lastError = nil
        mode = walking ? .walking : .cycling
        guard let route = await Self.route(from: here.coordinate, to: item, mode) else {
            let message = "Apple Maps found no \(walking ? "walking" : "cycling") route to \(name)"
            lastError = message
            throw DeviceError.badArgument(message)
        }
        destination = item.placemark.coordinate; destinationName = name
        startGuidance(route)
        return ["state": "guiding", "destination": name, "mode": walking ? "walking" : "cycling",
                "distance_m": Int(route.distance), "minutes": Int((route.expectedTravelTime / 60).rounded())]
    }

    // MARK: Guidance

    private func startGuidance(_ route: MKRoute) {
        guidance = NavigationGuidance(route: Self.navigationRoute(route))
        state = .guiding; startedAt = Date(); travelled = 0; offRouteFixes = 0; lastFix = nil
        cardKey = ""; cardStage = -1; sentGuide = nil; sentRemaining = nil
        send(InmoCommand.openModule(13))
        let imperial = countryCode == "USA"
        send(InmoCommand.appNotification(title: "Directions to \(destinationName ?? "your place")",
                                         content: "\(mode == .walking ? "Walking" : "Cycling") · \(NavigationCards.distance(route.distance, imperial: imperial)) · ETA \(NavigationGuidance.reachTime(Date().addingTimeInterval(route.expectedTravelTime)))"))
        send(InmoNavigationWire.remaining(meters: Int64(route.distance), seconds: Int64(route.expectedTravelTime),
                                          reachTime: NavigationGuidance.reachTime(Date().addingTimeInterval(route.expectedTravelTime)), countryCode: countryCode))
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        note("guiding \(mode == .walking ? "walking" : "cycling") \(Int(route.distance))m")
    }

    private func take(_ location: CLLocation) {
        for waiter in fixWaiters { waiter.resume(returning: location) }
        fixWaiters.removeAll()
        guard state == .guiding, var guidance, location.horizontalAccuracy > 0, location.horizontalAccuracy < 65 else { return }
        if let previous = lastFix {
            let moved = location.distance(from: previous)
            travelled += moved
            if moved > 3 { heading = NavigationGeo.bearing(previous.coordinate, location.coordinate) }
        }
        if location.course >= 0, location.speed > 0.7 { heading = location.course }
        lastFix = location
        let update = guidance.update(at: location.coordinate, now: Date())
        self.guidance = guidance
        last = update
        if update.arrived { return arrive() }
        // Each write takes ~360 ms to be acknowledged over GATT-over-Classic, so only send
        // what changed, and never queue a minimap behind one still going out.
        if sentGuide.map({ $0.guideType != update.guideType || $0.roadName != update.roadName || abs($0.toManeuver - update.toManeuver) >= 5 }) ?? true {
            sentGuide = update
            send(InmoNavigationWire.guide(type: update.guideType, road: update.roadName, meters: update.toManeuver, countryCode: countryCode))
        }
        if sentRemaining.map({ abs($0.remaining - update.remaining) >= 10 || $0.reachTime != update.reachTime }) ?? true {
            sentRemaining = update
            send(InmoNavigationWire.remaining(meters: update.remaining, seconds: update.remainingSeconds, reachTime: update.reachTime, countryCode: countryCode))
        }
        // The lens doesn't draw the navigation stream on firmware Go3_DC_V1.1.295 — not even
        // the official app's (2026-09-27 trace) — so each turn also goes out as a card, which it
        // does draw: announced, again when close, and at the turn. (No minimap: nothing shows it,
        // and one ties up the link for ~5 s.)
        let key = "\(update.guideType)|\(update.roadName)"
        let stage = NavigationCards.stage(toManeuver: update.toManeuver, walking: mode == .walking)
        if key != cardKey || stage > cardStage {
            cardKey = key; cardStage = stage
            let card = NavigationCards.turn(update, imperial: countryCode == "USA")
            send(InmoCommand.appNotification(title: card.title, content: card.body))
        }
        offRouteFixes = update.offRoute > 50 ? offRouteFixes + 1 : 0
        if offRouteFixes >= 3, !replanning { replan(from: location.coordinate) }
    }

    private func replan(from here: CLLocationCoordinate2D) {
        guard let destination else { return }
        replanning = true
        note("off route — re-planning")
        Task {
            defer { replanning = false }
            guard state == .guiding, let route = await Self.route(from: here, to: MKMapItem(placemark: MKPlacemark(coordinate: destination)), mode) else { return }
            guidance = NavigationGuidance(route: Self.navigationRoute(route))
            offRouteFixes = 0
            send(InmoNavigationWire.remaining(meters: Int64(route.distance), seconds: Int64(route.expectedTravelTime),
                                              reachTime: NavigationGuidance.reachTime(Date().addingTimeInterval(route.expectedTravelTime)), countryCode: countryCode))
        }
    }

    private func arrive() {
        let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
        send(InmoNavigationWire.arrived(meters: Int64(travelled.rounded()), seconds: Int64(Date().timeIntervalSince(startedAt)), countryCode: countryCode, image: nil))
        send(InmoCommand.appNotification(title: "Arrived · \(destinationName ?? "destination")",
                                         content: "\(NavigationCards.distance(travelled, imperial: countryCode == "USA")) in \(minutes / 60 > 0 ? "\(minutes / 60) h " : "")\(minutes % 60) min"))
        stopLocation()
        state = .arrived
        note("arrived after \(Int(travelled))m")
    }

    /// Stop guidance. From the phone (voice, the Places page) the lens is told to close
    /// Navigation too; when the lens closed it, it needs no answer.
    func stop(fromLens: Bool) {
        if !fromLens, state != .idle { send(InmoCommand.closeModule(13)) }
        end(fromLens ? "closed on the lens" : "stopped from the phone")
    }
    private func end(_ why: String) {
        stopLocation()
        guidance = nil; plans = (nil, nil); state = .idle
        note("navigation ended: \(why)")
    }
    private func fail(_ message: String) {
        lastError = message
        send(InmoNavigationWire.permission(false))
        stopLocation(); state = .idle
        note("navigation failed: \(message)")
    }
    private func stopLocation() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        for waiter in fixWaiters { waiter.resume(returning: nil) }
        fixWaiters.removeAll()
    }

    // MARK: Helpers

    /// A recent fix, or a fresh one (up to 15 s). nil when location is off or denied.
    private func currentFix() async -> CLLocation? {
        if let recent = manager.location, Date().timeIntervalSince(recent.timestamp) < 30, (0..<100).contains(recent.horizontalAccuracy) { return recent }
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        manager.requestLocation()
        return await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.fixWaiters.isEmpty else { return }
                for waiter in self.fixWaiters { waiter.resume(returning: nil) }
                self.fixWaiters.removeAll()
            }
        }
    }

    private static func route(from: CLLocationCoordinate2D, to: MKMapItem, _ type: MKDirectionsTransportType) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = to
        request.transportType = type
        return try? await MKDirections(request: request).calculate().routes.first
    }

    static func navigationRoute(_ route: MKRoute) -> NavigationRoute {
        NavigationRoute(steps: route.steps.map { step in
            let polyline = step.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            return .init(instructions: step.instructions, points: coordinates)
        }, expectedTime: route.expectedTravelTime)
    }

    /// Writes go out in order (a guide update must never overtake the module open).
    private func send(_ data: Data, then done: (@MainActor () -> Void)? = nil) {
        guard session.isReady else { done?(); return }
        let previous = sendChain
        sendChain = Task { [session] in
            await previous?.value
            try? await session.send(data)
            done?()
        }
    }
    private func note(_ line: String) { InmoRuntimeDiagnostics.note("nav " + line) }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.take(location) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            for waiter in self.fixWaiters { waiter.resume(returning: nil) }
            self.fixWaiters.removeAll()
        }
    }
}
