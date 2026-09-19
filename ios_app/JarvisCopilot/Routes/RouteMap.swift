import MapKit
import SwiftUI

/// What colours a route line.
enum RouteColouring: String, CaseIterable, Identifiable {
    case plain, pace, elevation, heartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "Route"
        case .pace: return "Pace"
        case .elevation: return "Elevation"
        case .heartRate: return "Heart rate"
        }
    }

    /// The two ends of the scale, for the legend.
    var ends: (String, String)? {
        switch self {
        case .plain: return nil
        case .pace: return ("Slower", "Faster")
        case .elevation: return ("Lower", "Higher")
        case .heartRate: return ("Zone 1", "Zone 5")
        }
    }
}

/// The colours a route is drawn in, point by point.
enum RoutePalette {
    static let paceRamp: [UInt32] = [JcTheme.dangerHex, JcTheme.amberHex, JcTheme.successHex, JcAccent.hex]
    static let elevationRamp: [UInt32] = [JcAccent.hex, JcTheme.successHex, JcTheme.amberHex, JcTheme.dangerHex]

    static func ramp(_ colouring: RouteColouring) -> [Color] {
        switch colouring {
        case .plain: return [JcTheme.accent]
        case .pace: return paceRamp.map { Color(jcHex: $0) }
        case .elevation: return elevationRamp.map { Color(jcHex: $0) }
        case .heartRate: return (1...5).map(WorkoutLiveView.zoneTint)
        }
    }

    /// One colour per point of each segment; nil draws the plain accent line.
    static func colors(_ route: WorkoutRoute, stats: RouteStats, colouring: RouteColouring, age: Int) -> [[UIColor]]? {
        guard colouring != .plain, stats.samples.count == route.points.count else { return nil }
        let values: [Double?] = stats.samples.map { sample in
            switch colouring {
            case .pace: return sample.speed
            case .elevation: return sample.ele
            case .heartRate: return sample.hr.map(Double.init)
            case .plain: return nil
            }
        }
        let known = values.compactMap { $0 }.sorted()
        guard known.count >= 2 else { return nil }
        let lo = known[Int(Double(known.count - 1) * 0.05)], hi = known[Int(Double(known.count - 1) * 0.95)]
        let neutral = UIColor(JcTheme.muted)
        var out: [[UIColor]] = []
        var offset = 0
        for segment in route.segments {
            out.append((0..<segment.count).map { i in
                guard let v = values[offset + i] else { return neutral }
                if colouring == .heartRate {
                    return UIColor(WorkoutLiveView.zoneTint(RingWorkoutController.zone(Int(v), age: age)))
                }
                let t = hi > lo ? max(0, min(1, (v - lo) / (hi - lo))) : 0.5
                return blend(colouring == .pace ? paceRamp : elevationRamp, t)
            })
            offset += segment.count
        }
        return out
    }

    static func blend(_ stops: [UInt32], _ t: Double) -> UIColor {
        let position = t * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(position))
        let f = position - Double(i)
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
        let a = stops[i], b = stops[i + 1]
        return UIColor(red: channel(a, 16) + (channel(b, 16) - channel(a, 16)) * f,
                       green: channel(a, 8) + (channel(b, 8) - channel(a, 8)) * f,
                       blue: channel(a, 0) + (channel(b, 0) - channel(a, 0)) * f, alpha: 1)
    }
}

/// A pin on the route: where it began and ended, each mile or km, and the
/// scrubbed point.
struct RouteMarker: Identifiable, Equatable {
    enum Kind: Equatable { case start, finish, split(Int) }
    var kind: Kind
    var coordinate: CLLocationCoordinate2D

    var id: String {
        switch kind {
        case .start: return "start"
        case .finish: return "finish"
        case .split(let n): return "split-\(n)"
        }
    }

    static func == (a: RouteMarker, b: RouteMarker) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }

    /// Start, finish and a marker where each full unit ends.
    static func markers(_ route: WorkoutRoute, stats: RouteStats, unit: DistanceUnit) -> [RouteMarker] {
        guard let first = route.points.first, let last = route.points.last else { return [] }
        var out = [RouteMarker(kind: .start, coordinate: first.coordinate)]
        var next = unit.meters
        var number = 1
        for sample in stats.samples where sample.distance >= next {
            out.append(RouteMarker(kind: .split(number), coordinate: CLLocationCoordinate2D(latitude: sample.lat,
                                                                                          longitude: sample.lon)))
            number += 1
            next += unit.meters
        }
        out.append(RouteMarker(kind: .finish, coordinate: last.coordinate))
        return out
    }
}

/// A route on a map (MapKit's own view: SwiftUI's Map can't draw a line in
/// changing colours or a contour layer). Standard is the dark muted map,
/// Satellite the hybrid, Topo OpenTopoMap's contours over nothing else.
struct RouteMapView: UIViewRepresentable {
    var segments: [[RoutePoint]]
    /// Changes whenever `segments` or `colors` do: the line is redrawn only then.
    var revision: Int
    var style: MapStyle
    var colors: [[UIColor]]? = nil
    var markers: [RouteMarker] = []
    /// A route being followed, dashed under this one.
    var guide: [CLLocationCoordinate2D]? = nil
    var scrub: CLLocationCoordinate2D? = nil
    var showsUser = false
    /// The camera follows the person; a pan lets go of it.
    var following: Binding<Bool>? = nil
    /// Frames the whole route (again whenever this changes).
    var fitToken: Int? = 0
    var insets = UIEdgeInsets(top: 40, left: 30, bottom: 40, right: 30)
    var interactive = true

    static let topoTemplate = "https://tile.opentopomap.org/{z}/{x}/{y}.png"
    static let topoCredit = "© OpenTopoMap (CC-BY-SA) · © OpenStreetMap"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.tintColor = UIColor(JcTheme.accent)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.showsScale = false
        let credit = context.coordinator.credit
        credit.text = Self.topoCredit
        credit.font = .systemFont(ofSize: 9, weight: .medium)
        credit.textColor = UIColor.black.withAlphaComponent(0.75)
        credit.backgroundColor = UIColor.white.withAlphaComponent(0.6)
        credit.layer.cornerRadius = 3
        credit.clipsToBounds = true
        credit.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(credit)
        NSLayoutConstraint.activate([
            credit.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -6),
            credit.bottomAnchor.constraint(equalTo: map.bottomAnchor, constant: -4),
        ])
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        map.isScrollEnabled = interactive
        map.isZoomEnabled = interactive
        map.isRotateEnabled = interactive
        map.isPitchEnabled = interactive
        if c.style != style { c.apply(style, to: map) }
        if c.revision != revision { c.drawRoute(on: map) }
        c.drawGuide(on: map)
        c.placeMarkers(on: map)
        c.placeScrub(on: map)
        map.showsUserLocation = showsUser
        if let following, following.wrappedValue { c.follow(map) }
        if let fitToken, c.fitted != fitToken, !segments.joined().isEmpty {
            c.fitted = fitToken
            c.fit(map)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapView
        var style: MapStyle?
        var revision = -1
        var fitted: Int?
        let credit = UILabel()
        /// Following has framed the runner once; after that it only pans.
        private var zoomed = false
        private var followedRevision = -1
        /// The camera is moving because this code moved it, not a finger.
        private var moving = false
        private var routeOverlays: [MKPolyline] = []
        private var casings: Set<ObjectIdentifier> = []
        private var gradient: [ObjectIdentifier: [UIColor]] = [:]
        private var tile: MKTileOverlay?
        private var guideLine: MKPolyline?
        private var guideKey: String?
        private var pins: [String: RoutePin] = [:]
        private var scrubPin: RoutePin?

        init(_ parent: RouteMapView) { self.parent = parent }

        func apply(_ style: MapStyle, to map: MKMapView) {
            self.style = style
            if let tile { map.removeOverlay(tile) }
            tile = nil
            switch style {
            case .standard:
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            case .satellite:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            case .topo:
                map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
                let overlay = MKTileOverlay(urlTemplate: RouteMapView.topoTemplate)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = 17
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                tile = overlay
            }
            credit.isHidden = style != .topo
            credit.text = " \(RouteMapView.topoCredit) "
        }

        func drawRoute(on map: MKMapView) {
            revision = parent.revision
            map.removeOverlays(routeOverlays)
            routeOverlays = []
            casings = []
            gradient = [:]
            for (index, segment) in parent.segments.enumerated() where segment.count >= 2 {
                let coordinates = segment.map(\.coordinate)
                let casing = MKPolyline(coordinates: coordinates, count: coordinates.count)
                let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                casings.insert(ObjectIdentifier(casing))
                if let colors = parent.colors, index < colors.count, colors[index].count == segment.count {
                    gradient[ObjectIdentifier(line)] = colors[index]
                }
                map.addOverlay(casing, level: .aboveLabels)
                map.addOverlay(line, level: .aboveLabels)
                routeOverlays += [casing, line]
            }
        }

        func drawGuide(on map: MKMapView) {
            let key = parent.guide.map { "\($0.count)-\($0.first?.latitude ?? 0)-\($0.last?.longitude ?? 0)" }
            guard key != guideKey else { return }
            guideKey = key
            if let guideLine { map.removeOverlay(guideLine) }
            guideLine = nil
            guard let guide = parent.guide, guide.count >= 2 else { return }
            let line = MKPolyline(coordinates: guide, count: guide.count)
            // Under the recorded route, over the map.
            if let first = routeOverlays.first {
                map.insertOverlay(line, below: first)
            } else {
                map.addOverlay(line, level: .aboveLabels)
            }
            guideLine = line
        }

        func placeMarkers(on map: MKMapView) {
            let wanted = Dictionary(uniqueKeysWithValues: parent.markers.map { ($0.id, $0) })
            for (id, pin) in pins where wanted[id] == nil || wanted[id]?.coordinate.latitude != pin.coordinate.latitude {
                map.removeAnnotation(pin)
                pins[id] = nil
            }
            for (id, marker) in wanted where pins[id] == nil {
                let pin = RoutePin(kind: .marker(marker.kind), coordinate: marker.coordinate)
                pins[id] = pin
                map.addAnnotation(pin)
            }
        }

        func placeScrub(on map: MKMapView) {
            guard let scrub = parent.scrub else {
                if let scrubPin { map.removeAnnotation(scrubPin) }
                scrubPin = nil
                return
            }
            if let scrubPin {
                scrubPin.coordinate = scrub
            } else {
                let pin = RoutePin(kind: .scrub, coordinate: scrub)
                scrubPin = pin
                map.addAnnotation(pin)
            }
        }

        /// Keeps the newest point of the route (else the phone's own
        /// location) in the middle: framed at a few streets across once,
        /// then panned along as the route grows.
        func follow(_ map: MKMapView) {
            let target = parent.segments.last(where: { !$0.isEmpty })?.last?.coordinate
                ?? (map.userLocation.location.map(\.coordinate))
            guard let target, CLLocationCoordinate2DIsValid(target) else { return }
            moving = true
            if !zoomed {
                zoomed = true
                map.setRegion(MKCoordinateRegion(center: target, latitudinalMeters: 900, longitudinalMeters: 900),
                              animated: false)
            } else if followedRevision != parent.revision || map.centerCoordinate.latitude != target.latitude {
                map.setCenter(target, animated: true)
            }
            followedRevision = parent.revision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.moving = false }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard parent.following?.wrappedValue == true, parent.segments.joined().isEmpty else { return }
            follow(mapView)
        }

        /// A finger moved the map: stop following until asked again.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard !moving, let following = parent.following, following.wrappedValue else { return }
            let recognizers = (mapView.gestureRecognizers ?? []) + (mapView.subviews.first?.gestureRecognizers ?? [])
            let touched = recognizers.contains { $0.state == .began || $0.state == .changed }
            if touched { DispatchQueue.main.async { following.wrappedValue = false } }
        }

        func fit(_ map: MKMapView) {
            let rect = parent.segments.joined().reduce(MKMapRect.null) { rect, point in
                let p = MKMapPoint(point.coordinate)
                return rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
            }
            guard !rect.isNull else { return }
            // Never closer than a few hundred metres: a short route stays in context.
            let minimum = MKMapPointsPerMeterAtLatitude(parent.segments.joined().first?.lat ?? 0) * 400
            var padded = rect
            if padded.width < minimum { padded = padded.insetBy(dx: -(minimum - padded.width) / 2, dy: 0) }
            if padded.height < minimum { padded = padded.insetBy(dx: 0, dy: -(minimum - padded.height) / 2) }
            map.setVisibleMapRect(padded, edgePadding: parent.insets, animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            if line === guideLine {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.white.withAlphaComponent(0.75)
                r.lineWidth = 4
                r.lineDashPattern = [2, 9]
                r.lineCap = .round
                return r
            }
            if casings.contains(ObjectIdentifier(line)) {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.black.withAlphaComponent(0.55)
                r.lineWidth = 8.5
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            let r = MKGradientPolylineRenderer(polyline: line)
            if let colors = gradient[ObjectIdentifier(line)], colors.count >= 2 {
                // At most a few hundred stops: enough for any route's colours.
                let step = max(1, colors.count / 300)
                let picked = stride(from: 0, to: colors.count, by: step).map { $0 }
                r.setColors(picked.map { colors[$0] },
                            locations: picked.map { CGFloat($0) / CGFloat(colors.count - 1) })
            } else {
                r.setColors([UIColor(JcTheme.accent)], locations: [])
                r.strokeColor = UIColor(JcTheme.accent)
            }
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? RoutePin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: pin.reuse)
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: pin.reuse)
            view.annotation = pin
            view.image = pin.image
            view.canShowCallout = false
            view.displayPriority = .required
            view.zPriority = pin.kind == .scrub ? .max : .defaultSelected
            return view
        }

    }
}

/// A pin the route map draws itself.
final class RoutePin: NSObject, MKAnnotation {
    enum Kind: Equatable { case marker(RouteMarker.Kind), scrub }
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(kind: Kind, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
    }

    var reuse: String {
        switch kind {
        case .scrub: return "scrub"
        case .marker(.start): return "start"
        case .marker(.finish): return "finish"
        case .marker(.split(let n)): return "split-\(n)"
        }
    }

    var image: UIImage {
        switch kind {
        case .scrub:
            return Self.dot(diameter: 18, fill: .white, ring: UIColor(JcTheme.accent), ringWidth: 4)
        case .marker(.start):
            return Self.dot(diameter: 16, fill: UIColor(JcTheme.success), ring: .white, ringWidth: 2.5)
        case .marker(.finish):
            return Self.badge(symbol: "flag.checkered", diameter: 24)
        case .marker(.split(let n)):
            return Self.label("\(n)", diameter: 20)
        }
    }

    static func dot(diameter: CGFloat, fill: UIColor, ring: UIColor, ringWidth: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
            let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ring.setFill()
            context.cgContext.fillEllipse(in: rect)
            fill.setFill()
            context.cgContext.fillEllipse(in: rect.insetBy(dx: ringWidth, dy: ringWidth))
        }
    }

    static func badge(symbol: String, diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
            let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: rect)
            let config = UIImage.SymbolConfiguration(pointSize: diameter * 0.5, weight: .bold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.black, renderingMode: .alwaysOriginal) {
                glyph.draw(in: CGRect(x: (diameter - glyph.size.width) / 2, y: (diameter - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }
    }

    static func label(_ text: String, diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
            let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: rect)
            UIColor(white: 0.08, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: text.count > 1 ? 9 : 10.5, weight: .bold), .foregroundColor: UIColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (diameter - size.width) / 2, y: (diameter - size.height) / 2),
                                    withAttributes: attributes)
        }
    }
}

/// A round glass button over a map.
struct MapCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .jcLiquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The layer switcher: Standard, Satellite, Topo. The choice becomes the default.
struct MapStyleButton: View {
    @Binding var style: MapStyle

    var body: some View {
        Menu {
            Picker("Map", selection: Binding(get: { style }, set: { style = $0; MapStyle.current = $0 })) {
                ForEach(MapStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .jcLiquidGlass(in: Circle())
        }
        .accessibilityLabel("Map style")
    }
}
