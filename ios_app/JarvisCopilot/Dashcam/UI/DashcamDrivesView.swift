import Charts
import CoreLocation
import SwiftUI

/// Drives built from the GPS in every clip: newest first, with miles, time and top speed.
struct DashcamDrivesView: View {
    @State private var drives: [DashcamDrive] = []
    @State private var error: String?
    @State private var loading = true
    @ObservedObject private var sync: DashcamSync = .shared

    var body: some View {
        VStack(spacing: 14) {
            if !drives.isEmpty { weekSummary }
            if let error, drives.isEmpty {
                CardGroup { CardEmptyBlock("Couldn't load drives: \(error)", symbol: "exclamationmark.icloud") }
            } else if drives.isEmpty && !loading {
                CardGroup { CardEmptyBlock("No drives yet. Each sync reads the GPS in every clip and joins them into drives.", symbol: "car") }
            }
            ForEach(groupedByDay, id: \.0) { title, items in
                CardGroup(title) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, drive in
                        if i > 0 { RowDivider() }
                        NavigationLink { DashcamDriveDetailView(driveID: drive.id) } label: {
                            Row(minHeight: 60) { driveRow(drive) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: sync.lastSync) { _, _ in Task { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            drives = try await DashcamAPI().drives().sorted { $0.start > $1.start }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var groupedByDay: [(String, [DashcamDrive])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: drives) { cal.startOfDay(for: $0.start) }
        return groups.keys.sorted(by: >).map { day in
            let title = cal.isDateInToday(day) ? "Today" : cal.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            return (title, groups[day, default: []].sorted { $0.start > $1.start })
        }
    }

    private var weekSummary: some View {
        let week = drives.filter { $0.start > Date().addingTimeInterval(-7 * 86400) }
        return CardGroup("Last 7 days") {
            Row {
                HStack(spacing: 8) {
                    MetricPill(icon: "car.fill", label: "Drives", value: "\(week.count)", tint: JcTheme.accent)
                    MetricPill(icon: "road.lanes", label: "Distance", value: DashcamSpeed.miles(week.reduce(0) { $0 + $1.distanceM }),
                               tint: JcTheme.accent)
                    MetricPill(icon: "gauge.with.dots.needle.67percent", label: "Top",
                               value: "\(DashcamSpeed.text(week.map(\.maxMps).max())) mph", tint: JcTheme.amber)
                }
            }
        }
    }

    private func driveRow(_ d: DashcamDrive) -> some View {
        HStack(spacing: 12) {
            JcIcon("point.topleft.down.to.point.bottomright.curvepath", size: 20).foregroundStyle(JcTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(d.start.formatted(date: .omitted, time: .shortened)) – \(d.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.semibold))
                Text("\(DashcamSpeed.miles(d.distanceM)) · \(DashcamSpeed.duration(d.durationS)) · top \(DashcamSpeed.text(d.maxMps)) mph")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
        }
    }
}

/// One drive: the route coloured by speed, a speed chart you can scrub (the dot follows on the
/// map), stats, its clips, and GPX.
struct DashcamDriveDetailView: View {
    let driveID: String
    @State private var detail: DashcamDriveDetail?
    @State private var error: String?
    @State private var scrubT: Double?
    @State private var gpxURL: URL?
    @State private var aboveMph: Double = 70

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let detail {
                    map(detail)
                    chart(detail)
                    stats(detail)
                    clips(detail)
                } else if let error {
                    CardGroup { CardEmptyBlock(error, symbol: "exclamationmark.icloud") }
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(detail?.drive.start.formatted(date: .abbreviated, time: .shortened) ?? "Drive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let gpxURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: gpxURL) { JcIcon("square.and.arrow.up", size: 17).foregroundStyle(JcTheme.accent) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let d = try await DashcamAPI().drive(driveID)
            detail = d
            if let data = try? await DashcamAPI().gpx(driveID: driveID) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(driveID).gpx")
                try? data.write(to: url)
                gpxURL = url
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func points(_ d: DashcamDriveDetail) -> [RoutePoint] {
        d.polyline.enumerated().map { i, p in RoutePoint(t: p.t ?? Double(i), lat: p.lat, lon: p.lon, speed: p.speed) }
    }

    private func nearest(_ d: DashcamDriveDetail, _ t: Double) -> (lat: Double, lon: Double, speed: Double?, t: Double?)? {
        d.polyline.min { abs(($0.t ?? 0) - t) < abs(($1.t ?? 0) - t) }
    }

    private func map(_ d: DashcamDriveDetail) -> some View {
        let scrub = scrubT.flatMap { nearest(d, $0) }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        var markers: [RouteMarker] = []
        if let f = d.polyline.first { markers.append(.init(kind: .start, coordinate: .init(latitude: f.lat, longitude: f.lon))) }
        if let l = d.polyline.last { markers.append(.init(kind: .finish, coordinate: .init(latitude: l.lat, longitude: l.lon))) }
        return RouteMapView(segments: [points(d)], revision: d.polyline.count, style: .current,
                            colors: [d.polyline.map { DashcamSpeed.color($0.speed) }], markers: markers, scrub: scrub)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
    }

    @ViewBuilder private func chart(_ d: DashcamDriveDetail) -> some View {
        let samples = d.polyline.compactMap { p -> (t: Date, mph: Double)? in
            guard let t = p.t, let mph = DashcamSpeed.mph(p.speed) else { return nil }
            return (Date(timeIntervalSince1970: t), mph)
        }
        if samples.count >= 2 {
            CardGroup("Speed") {
                VStack(alignment: .leading, spacing: 6) {
                    if let t = scrubT, let p = nearest(d, t) {
                        Text("\(DashcamSpeed.text(p.speed)) mph at \(Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .standard))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("Drag across the chart to follow the drive").font(.caption).foregroundStyle(.secondary)
                    }
                    Chart {
                        ForEach(samples.indices, id: \.self) { i in
                            AreaMark(x: .value("Time", samples[i].t), y: .value("mph", samples[i].mph))
                                .foregroundStyle(LinearGradient(colors: [JcTheme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", samples[i].t), y: .value("mph", samples[i].mph))
                                .foregroundStyle(JcTheme.accent)
                        }
                        if let t = scrubT {
                            RuleMark(x: .value("Time", Date(timeIntervalSince1970: t))).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .chartYAxisLabel("mph")
                    .chartXSelection(value: Binding(get: { scrubT.map { Date(timeIntervalSince1970: $0) } },
                                                    set: { scrubT = $0?.timeIntervalSince1970 }))
                    .frame(height: 150)
                    if let t = scrubT, let clip = clipAt(d, t) {
                        NavigationLink {
                            DashcamPlayerView(clip: clip, siblings: d.clips, startOffset: max(0, t - clip.start.timeIntervalSince1970))
                        } label: {
                            Label("Play from here", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.jcGlass(compact: true))
                    }
                }
                .padding(16)
            }
        }
    }

    private func clipAt(_ d: DashcamDriveDetail, _ t: Double) -> DashcamServerClip? {
        let date = Date(timeIntervalSince1970: t)
        let videos = d.clips.filter { $0.kind != .photo && $0.start <= date && $0.end >= date }
        return videos.first { $0.lens == .front } ?? videos.first
    }

    private func stats(_ d: DashcamDriveDetail) -> some View {
        let speeds = d.polyline.compactMap { DashcamSpeed.mph($0.speed) }
        let above = speeds.isEmpty ? 0 : Double(speeds.filter { $0 > aboveMph }.count) / Double(speeds.count) * d.drive.movingS
        return CardGroup("Drive") {
            statRow("Distance", DashcamSpeed.miles(d.drive.distanceM))
            RowDivider()
            statRow("Time", DashcamSpeed.duration(d.drive.durationS) + " (moving \(DashcamSpeed.duration(d.drive.movingS)))")
            RowDivider()
            statRow("Average", "\(DashcamSpeed.text(d.drive.avgMps)) mph")
            RowDivider()
            statRow("Top speed", "\(DashcamSpeed.text(d.drive.maxMps)) mph")
            RowDivider()
            Row {
                HStack {
                    Stepper("Above \(Int(aboveMph)) mph", value: $aboveMph, in: 25...100, step: 5).foregroundStyle(.secondary)
                    Text(DashcamSpeed.duration(above)).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        Row { HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).font(.callout.monospacedDigit()) } }
    }

    private func clips(_ d: DashcamDriveDetail) -> some View {
        CardGroup("Clips") {
            ForEach(Array(d.clips.sorted { $0.start < $1.start }.enumerated()), id: \.element.id) { i, clip in
                if i > 0 { RowDivider() }
                NavigationLink { DashcamPlayerView(clip: clip, siblings: d.clips) } label: {
                    Row(minHeight: 64) { DashcamClipRow(clip: clip, uploadingID: nil) }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
