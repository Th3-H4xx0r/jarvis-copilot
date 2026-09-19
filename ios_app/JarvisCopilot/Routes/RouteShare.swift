import MapKit
import SwiftUI

/// A route as GPX 1.1: one track, a segment per stretch between pauses,
/// elevation, time and (Garmin's extension) heart rate on each point.
enum GPXWriter {
    static func gpx(_ route: WorkoutRoute, name: String) -> String {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime]
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Jarvis Copilot" xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata><name>\(escape(name))</name><time>\(time.string(from: route.start))</time></metadata>
          <trk>
            <name>\(escape(name))</name>

        """
        for segment in route.segments where !segment.isEmpty {
            out += "    <trkseg>\n"
            for p in segment {
                out += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\">", p.lat, p.lon)
                if let ele = p.ele { out += String(format: "<ele>%.1f</ele>", ele) }
                out += "<time>\(time.string(from: route.start.addingTimeInterval(p.t)))</time>"
                if let hr = p.hr {
                    out += "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(hr)</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"
                }
                out += "</trkpt>\n"
            }
            out += "    </trkseg>\n"
        }
        out += "  </trk>\n</gpx>\n"
        return out
    }

    /// Written where a share sheet can hand it on: "Run 2026-09-19.gpx".
    static func file(_ route: WorkoutRoute, name: String) throws -> URL {
        let day = route.start.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) \(day).gpx")
        try gpx(route, name: name).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A picture to share: the route on the map with its headline numbers.
@MainActor
enum RouteShareImage {
    static func make(_ route: WorkoutRoute, workout: RingWorkout, stats: RouteStats, unit: DistanceUnit,
                     style: MapStyle) async -> UIImage? {
        let points = route.points
        guard points.count >= 2 else { return nil }
        let rect = points.reduce(MKMapRect.null) { rect, p in
            let m = MKMapPoint(p.coordinate)
            return rect.union(MKMapRect(x: m.x, y: m.y, width: 1, height: 1))
        }
        let options = MKMapSnapshotter.Options()
        let padding = max(rect.width, rect.height) * 0.18 + MKMapPointsPerMeterAtLatitude(points[0].lat) * 150
        options.mapRect = rect.insetBy(dx: -padding, dy: -padding)
        options.size = CGSize(width: 1080, height: 1080)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.preferredConfiguration = style == .satellite
            ? MKHybridMapConfiguration() : MKStandardMapConfiguration(emphasisStyle: .muted)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let map = UIGraphicsImageRenderer(size: options.size).image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for (width, color) in [(18.0, UIColor.black.withAlphaComponent(0.55)), (10.0, UIColor(JcTheme.accent))] {
                cg.setLineWidth(width)
                cg.setStrokeColor(color.cgColor)
                for segment in route.segments where segment.count >= 2 {
                    cg.beginPath()
                    cg.move(to: snapshot.point(for: segment[0].coordinate))
                    for p in segment.dropFirst() { cg.addLine(to: snapshot.point(for: p.coordinate)) }
                    cg.strokePath()
                }
            }
            let start = snapshot.point(for: points[0].coordinate)
            UIColor.white.setFill()
            cg.fillEllipse(in: CGRect(x: start.x - 14, y: start.y - 14, width: 28, height: 28))
            UIColor(JcTheme.success).setFill()
            cg.fillEllipse(in: CGRect(x: start.x - 9, y: start.y - 9, width: 18, height: 18))
        }
        let card = VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: map).resizable().frame(width: 1080, height: 1080)
            HStack(spacing: 0) {
                figure("Distance", "\(unit.distance(stats.distance)) \(unit.symbol)")
                figure("Time", WorkoutLiveView.clock(Int(stats.moving)))
                figure("Pace", "\(unit.pace(secondsPerMeter: stats.movingPace))/\(unit.symbol)")
                figure("Climbed", "\(unit.elevation(stats.gain ?? 0)) \(unit.elevationSymbol)")
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            Text("\(workout.sportName) · \(workout.start.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 56)
                .padding(.bottom, 48)
        }
        .frame(width: 1080)
        .background(JcTheme.bg)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        return renderer.uiImage
    }

    private static func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 28, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 50, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
