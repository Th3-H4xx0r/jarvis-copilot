import SwiftUI

/// An outdoor workout, AllTrails-style: the route on a map coloured by what
/// you pick, the numbers that matter, a profile you can run a finger along
/// (the map's dot follows), splits, zones, and sharing. The same screen is
/// the summary when a workout ends (with Save and Discard) and a saved
/// workout from the Health tab.
struct RouteDetailView: View {
    let workout: RingWorkout
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    /// Pushed from the Health tab: it can be deleted.
    var fromHistory = false
    @State private var route: WorkoutRoute?
    @State private var loaded = false
    @State private var stats: RouteStats?
    @State private var series: [RouteChartKind: [RouteChartPoint]] = [:]
    @State private var markers: [RouteMarker] = []
    @State private var colors: [[UIColor]]?
    /// Bumps whenever the colours are worked out again (the map redraws on it).
    @State private var colorsVersion = 0
    @State private var colouring: RouteColouring = .plain
    @State private var profile: RouteChartKind = .elevation
    @State private var style = MapStyle.current
    @State private var scrub: Double?
    @State private var fullMap = false
    @State private var gpx: URL?
    @State private var picture: UIImage?
    @State private var confirmingDelete = false
    @State private var following = false
    /// Start pressed on the Follow sheet: the workout starts once it has gone.
    @State private var startAfterFollow: RingSport?
    @ObservedObject private var controller = WearablesHub.shared.ring.workout
    @AppStorage("jc.distance.unit") private var unitRaw = DistanceUnit.current.rawValue
    @Environment(\.dismiss) private var dismiss

    init(workout: RingWorkout, route: WorkoutRoute? = nil, onSave: (() -> Void)? = nil, onDiscard: (() -> Void)? = nil,
         fromHistory: Bool = false, colouring: RouteColouring = .plain) {
        self.workout = workout
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.fromHistory = fromHistory
        _route = State(initialValue: route)
        _colouring = State(initialValue: colouring)
    }

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .regional }
    private var age: Int { WearablesHub.shared.ring.session.settings.profile?.age ?? 30 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                header
                if let stats {
                    profileCard(stats)
                    details(stats)
                    splits(stats)
                } else if loaded {
                    missing
                }
                if workout.zoneSeconds.reduce(0, +) > 0 { WorkoutZonesCard(zoneSeconds: workout.zoneSeconds) }
                actions
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(JcTheme.bg)
        .task { await load() }
        .onChange(of: colouring) { _, _ in recolour() }
        .onChange(of: unitRaw) { _, _ in prepare() }
        .fullScreenCover(isPresented: $fullMap) {
            RouteFullMap(route: route, revision: revision, colors: colors, markers: markers, scrub: scrubCoordinate,
                         style: $style, colouring: $colouring, colourings: colourings)
        }
        .toolbar {
            if fromHistory {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let gpx { ShareLink(item: gpx) { Label("Export GPX", systemImage: "square.and.arrow.up") } }
                        Divider()
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete Workout", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Workout options")
                }
            }
        }
        .sheet(isPresented: $following, onDismiss: {
            // The workout's own sheet comes up only once this one has gone.
            if let sport = startAfterFollow { controller.start(sport) }
            startAfterFollow = nil
        }) {
            if let route {
                let sport = RingSport.withID(workout.sport).outdoor ? RingSport.withID(workout.sport) : RingSport.withID(7)
                NavigationStack {
                    WorkoutConfirmView(choice: .sport(sport),
                                       guide: RouteGuide(route: route, title: "\(workout.sportName) · \(workout.start.formatted(.dateTime.month(.abbreviated).day()))",
                                                         sport: workout.sport, start: workout.start)) { _ in
                        startAfterFollow = sport
                        following = false
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { following = false } } }
                }
            }
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                WorkoutEditing.delete(workout)
                dismiss()
            }
        } message: {
            Text("It goes from Jarvis Health and Apple Health, with its route.")
        }
    }

    // MARK: Loading

    private func load() async {
        if route == nil { route = await RouteStore.shared.load(workout) }
        loaded = true
        prepare()
        guard let route, let stats else { return }
        gpx = try? GPXWriter.file(route, name: workout.sportName)
        picture = await RouteShareImage.make(route, workout: workout, stats: stats, unit: unit, style: style)
    }

    private func prepare() {
        guard let route else { return }
        let computed = RouteMath.stats(route, unit: unit)
        stats = computed
        series = Dictionary(uniqueKeysWithValues: RouteChartKind.allCases.map {
            ($0, RouteChartSeries.points($0, stats: computed, unit: unit))
        })
        markers = RouteMarker.markers(route, stats: computed, unit: unit)
        if series[profile]?.isEmpty ?? true, let first = RouteChartKind.allCases.first(where: { !(series[$0]?.isEmpty ?? true) }) {
            profile = first
        }
        recolour()
    }

    private func recolour() {
        guard let route, let stats else { return }
        colors = RoutePalette.colors(route, stats: stats, colouring: colouring, age: age)
        colorsVersion &+= 1
    }

    private var revision: Int { (route?.points.count ?? 0) &* 1024 &+ colorsVersion }

    private var colourings: [RouteColouring] {
        RouteColouring.allCases.filter { c in
            switch c {
            case .plain: return true
            case .pace: return !(series[.pace]?.isEmpty ?? true)
            case .elevation: return !(series[.elevation]?.isEmpty ?? true)
            case .heartRate: return !(series[.heartRate]?.isEmpty ?? true)
            }
        }
    }

    /// Where the finger on the profile is, on the map.
    private var scrubCoordinate: CLLocationCoordinate2D? {
        guard let scrub, let samples = stats?.samples, !samples.isEmpty else { return nil }
        let target = scrub * unit.meters
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].distance < target { lo = mid + 1 } else { hi = mid }
        }
        return CLLocationCoordinate2D(latitude: samples[lo].lat, longitude: samples[lo].lon)
    }

    // MARK: Map

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                if let route {
                    RouteMapView(segments: route.segments, revision: revision, style: style, colors: colors,
                                 markers: markers, scrub: scrubCoordinate, fitToken: 1,
                                 insets: UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36), interactive: false)
                        .contentShape(Rectangle())
                        .onTapGesture { fullMap = true }
                        .accessibilityLabel("Route map")
                        .accessibilityHint("Opens the map full screen")
                        .accessibilityAddTraits(.isButton)
                } else {
                    Rectangle().fill(Color.white.opacity(0.04))
                        .overlay {
                            if !loaded {
                                ProgressView()
                            } else if let preview = workout.route?.preview, !preview.isEmpty {
                                RouteThumbnail(preview: preview, size: 180)
                            }
                        }
                }
                if route != nil {
                    VStack(spacing: 10) {
                        MapStyleButton(style: $style)
                        MapCircleButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full-screen map") {
                            fullMap = true
                        }
                    }
                    .padding(12)
                }
            }
            .frame(height: onSave == nil ? 320 : 360)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, onSave == nil ? 4 : 40)

            if colourings.count > 1 {
                Picker("Colour the route by", selection: $colouring) {
                    ForEach(colourings) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                if colouring != .plain { RouteLegend(colouring: colouring).padding(.horizontal, 20) }
            }
        }
    }

    // MARK: Numbers

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(workout.sportName, systemImage: RingSport.withID(workout.sport).symbol)
                    .font(.headline)
                    .foregroundStyle(JcTheme.accent)
                Text("\(workout.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(workout.start.formatted(date: .omitted, time: .shortened)) – \(workout.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 16) {
                headline("Distance", unit.distance(distance), unit.symbol)
                headline("Moving time", WorkoutLiveView.clock(movingSeconds), nil)
                headline("Avg pace", unit.pace(secondsPerMeter: movingPace), "/\(unit.symbol)")
                headline("Elevation gain", (stats?.gain ?? workout.route?.gainMeters).map { unit.elevation($0) } ?? "--",
                         unit.elevationSymbol)
            }
        }
        .padding(.horizontal, 24)
    }

    private var distance: Double { stats?.distance ?? workout.route?.distanceMeters ?? workout.distanceMeters }
    private var movingSeconds: Int { stats.map { Int($0.moving.rounded()) } ?? workout.route?.movingSeconds ?? workout.activeSeconds }
    private var movingPace: Double? { distance > 0 && movingSeconds > 0 ? Double(movingSeconds) / distance : nil }

    private func headline(_ label: String, _ value: String, _ suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let suffix { Text(suffix).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func profileCard(_ stats: RouteStats) -> some View {
        let kinds = RouteChartKind.allCases.filter { !(series[$0]?.isEmpty ?? true) }
        let points = series[profile] ?? []
        return CardGroup("Profile") {
            VStack(alignment: .leading, spacing: 12) {
                if kinds.count > 1 {
                    Picker("Profile", selection: $profile) {
                        ForEach(kinds) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                readout
                if points.count >= 2 {
                    RouteProfileChart(kind: profile, points: points, unit: unit, scrub: $scrub)
                        .frame(height: 160)
                } else {
                    Text("Not enough readings to chart.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    /// What the finger is on: how far along, and every value there.
    private var readout: some View {
        let target = scrub.map { $0 * unit.meters }
        let sample = target.flatMap { t in stats?.samples.min { abs($0.distance - t) < abs($1.distance - t) } }
        let parts: [String] = sample.map { s in
            [String(format: "%.2f %@", s.distance / unit.meters, unit.symbol),
             s.ele.map { "\(unit.elevation($0)) \(unit.elevationSymbol)" },
             s.speed.flatMap { $0 >= RouteMath.movingSpeed ? "\(unit.pace(secondsPerMeter: 1 / $0))/\(unit.symbol)" : nil },
             s.hr.map { "\($0) bpm" }].compactMap { $0 }
        } ?? []
        return Text(parts.isEmpty ? "Run a finger along the chart" : parts.joined(separator: " · "))
            .font(.subheadline.weight(parts.isEmpty ? .regular : .semibold))
            .foregroundStyle(parts.isEmpty ? .secondary : .primary)
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private func details(_ stats: RouteStats) -> some View {
        let best = stats.best.map { stats.splits[$0] }
        let total = Int(workout.end.timeIntervalSince(workout.start))
        let items: [(String, String?)] = [
            ("Total time", WorkoutLiveView.clock(total)),
            ("Avg speed", stats.averageSpeed.map { "\(unit.speed($0)) \(unit.speedSymbol)" }),
            ("Max speed", stats.maxSpeed.map { "\(unit.speed($0)) \(unit.speedSymbol)" }),
            ("Best \(unit.symbol)", best.map { "\(unit.pace(secondsPerMeter: $0.pace))/\(unit.symbol)" }),
            ("Elevation loss", stats.loss.map { "\(unit.elevation($0)) \(unit.elevationSymbol)" }),
            ("Highest", stats.maxEle.map { "\(unit.elevation($0)) \(unit.elevationSymbol)" }),
            ("Lowest", stats.minEle.map { "\(unit.elevation($0)) \(unit.elevationSymbol)" }),
            ("Avg heart rate", workout.heartRateAverage.map { "\($0) bpm" }),
            ("Max heart rate", workout.heartRateMax.map { "\($0) bpm" }),
            (workout.kcalSource == "estimate" ? "Calories (est.)" : "Calories",
             workout.kilocalories > 0 ? "\(Int(workout.kilocalories.rounded())) kcal" : nil),
            ("Steps", workout.steps > 0 ? workout.steps.formatted() : nil),
            ("Cadence", workout.steps > 0 && workout.activeSeconds >= 60
                ? "\(Int(Double(workout.steps) / (Double(workout.activeSeconds) / 60))) spm" : nil),
            ("Effort", workout.effort.map { "\($0) / 10" }),
        ]
        return CardGroup("Details") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(items.filter { $0.1 != nil }, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.1 ?? "")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
        }
    }

    private func splits(_ stats: RouteStats) -> some View {
        let hr = stats.splits.contains { $0.hr != nil }
        return CardGroup("Splits") {
            if stats.splits.isEmpty {
                Text("Shorter than a \(unit == .km ? "kilometre" : "mile").")
                    .font(.subheadline).foregroundStyle(.secondary).padding(16)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(unit.symbol.uppercased()).frame(width: 44, alignment: .leading)
                        Text("PACE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("ELEV").frame(width: 92, alignment: .leading)
                        if hr { Text("HR").frame(width: 44, alignment: .trailing) }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    ForEach(Array(stats.splits.enumerated()), id: \.element.id) { index, split in
                        RowDivider()
                        splitRow(split, fastest: index == stats.best, hr: hr)
                    }
                }
            }
        }
    }

    private func splitRow(_ split: RouteSplit, fastest: Bool, hr: Bool) -> some View {
        HStack {
            Text(split.partial ? String(format: "%.2f", split.meters / unit.meters) : "\(split.number)")
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(split.partial ? .secondary : .primary)
            HStack(spacing: 6) {
                Text(unit.pace(secondsPerMeter: split.pace))
                    .foregroundStyle(fastest ? JcTheme.accent : .primary)
                if fastest {
                    Text("FASTEST")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(JcTheme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(JcTheme.accent.opacity(0.14), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("↑\(unit.elevation(split.gain)) ↓\(unit.elevation(split.loss))")
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            if hr { Text(split.hr.map(String.init) ?? "--").frame(width: 44, alignment: .trailing) }
        }
        .font(.system(.subheadline, design: .rounded).weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var missing: some View {
        CardGroup(footer: "It's kept by Jarvis Health; this iPhone doesn't have a copy.") {
            Row(minHeight: 60) {
                HStack(spacing: 12) {
                    Image(systemName: "map").foregroundStyle(.secondary).frame(width: 30)
                    Text("The route couldn't be loaded.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        loaded = false
                        Task { await load() }
                    }
                    .buttonStyle(.jcGlass(compact: true))
                }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        if route != nil {
            HStack(spacing: 12) {
                if let gpx {
                    ShareLink(item: gpx) { Label("GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                        .buttonStyle(.jcGlass(compact: true))
                }
                if let picture {
                    ShareLink(item: Image(uiImage: picture),
                              preview: SharePreview("\(workout.sportName) route", image: Image(uiImage: picture))) {
                        Label("Image", systemImage: "photo")
                    }
                    .buttonStyle(.jcGlass(compact: true))
                }
                // Not while a workout runs: it would swap that workout's route.
                if fromHistory, !controller.isActive {
                    Button { following = true } label: { Label("Follow", systemImage: "arrow.triangle.turn.up.right.diamond") }
                        .buttonStyle(.jcGlass(compact: true))
                }
            }
            .padding(.horizontal, 24)
        }
        if onSave != nil || onDiscard != nil {
            HStack(spacing: 14) {
                if let onDiscard {
                    Button("Discard", action: onDiscard).buttonStyle(.jcGlass(tint: .secondary))
                }
                if let onSave {
                    Button("Save to Health", action: onSave).buttonStyle(.jcGlass(tint: JcTheme.accent))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }
}

/// The colour scale under the map.
struct RouteLegend: View {
    let colouring: RouteColouring

    var body: some View {
        HStack(spacing: 8) {
            Text(colouring.ends?.0 ?? "").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Capsule()
                .fill(LinearGradient(colors: RoutePalette.ramp(colouring), startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
            Text(colouring.ends?.1 ?? "").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(colouring.title): \(colouring.ends?.0 ?? "") to \(colouring.ends?.1 ?? "")")
    }
}

/// The route map on the whole screen, to pan and zoom.
struct RouteFullMap: View {
    let route: WorkoutRoute?
    let revision: Int
    let colors: [[UIColor]]?
    let markers: [RouteMarker]
    let scrub: CLLocationCoordinate2D?
    @Binding var style: MapStyle
    @Binding var colouring: RouteColouring
    let colourings: [RouteColouring]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            RouteMapView(segments: route?.segments ?? [], revision: revision, style: style, colors: colors, markers: markers,
                         scrub: scrub, fitToken: 1, insets: UIEdgeInsets(top: 110, left: 40, bottom: 140, right: 40),
                         margins: UIEdgeInsets(top: 8, left: 16, bottom: colourings.count > 1 ? 150 : 40, right: 16))
                .ignoresSafeArea()
            HStack(alignment: .top) {
                MapCircleButton(symbol: "xmark", label: "Close") { dismiss() }
                Spacer()
                MapStyleButton(style: $style)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if colourings.count > 1 {
                VStack(spacing: 10) {
                    Picker("Colour the route by", selection: $colouring) {
                        ForEach(colourings) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if colouring != .plain { RouteLegend(colouring: colouring) }
                }
                .padding(14)
                .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Time in each heart-rate zone.
struct WorkoutZonesCard: View {
    let zoneSeconds: [Int]

    var body: some View {
        CardGroup("Heart-rate zones") {
            VStack(spacing: 10) {
                ForEach((1...5).reversed(), id: \.self) { zone in
                    let seconds = zone - 1 < zoneSeconds.count ? zoneSeconds[zone - 1] : 0
                    let total = max(1, zoneSeconds.reduce(0, +))
                    HStack(spacing: 10) {
                        Text("Zone \(zone)").font(.caption.weight(.semibold)).frame(width: 52, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(WorkoutLiveView.zoneTint(zone))
                                .frame(width: max(4, proxy.size.width * CGFloat(seconds) / CGFloat(total)))
                        }
                        .frame(height: 10)
                        Text(seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(16)
        }
    }
}
