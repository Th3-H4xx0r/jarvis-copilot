import CoreLocation
import SwiftUI

/// An outdoor workout under way: the map on top following you and drawing
/// the route so far, the numbers below, pause and end at the bottom. The map
/// expands to the whole screen with the essentials in a strip.
struct RouteLiveView: View {
    @ObservedObject var workout: RingWorkoutController
    @AppStorage("jc.distance.unit") private var unitRaw = DistanceUnit.current.rawValue
    @State private var style = MapStyle.current
    @State private var following = true
    @State private var expanded = false
    @State private var confirmingEnd = false
    @State private var locationOff = false

    init(workout: RingWorkoutController, expanded: Bool = false) {
        self.workout = workout
        _expanded = State(initialValue: expanded)
    }

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .regional }
    private var progress: RouteProgress { workout.routeProgress }
    /// A wearable is recording heart rate.
    private var hasWearable: Bool { !workout.phoneOnly }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                map
                    .frame(height: expanded ? max(0, geometry.size.height - 132) : geometry.size.height * 0.45)
                if expanded {
                    strip
                } else {
                    ScrollView {
                        stats.padding(.top, 18)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    controls
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: expanded)
        .confirmationDialog("End workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End workout", role: .destructive) { workout.end() }
            Button("Keep going", role: .cancel) {}
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: workout.phase)
        .onAppear {
            let status = CLLocationManager().authorizationStatus
            locationOff = status == .denied || status == .restricted
        }
    }

    // MARK: Map

    private var map: some View {
        let route = workout.liveRoute
        let start = route?.points.first.map { [RouteMarker(kind: .start, coordinate: $0.coordinate)] } ?? []
        return ZStack(alignment: .top) {
            RouteMapView(segments: route?.segments ?? [], revision: progress.revision, style: style, markers: start,
                         showsUser: true, following: $following, fitToken: nil,
                         insets: UIEdgeInsets(top: 60, left: 40, bottom: 40, right: 60))
                .ignoresSafeArea(edges: .top)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    chip(workout.sport?.name ?? "Workout", symbol: workout.sport?.symbol ?? "figure.run", tint: .white)
                    if workout.phase == .paused { chip("Paused", symbol: "pause.fill", tint: JcTheme.amber) }
                    if locationOff {
                        chip("Location is off — allow it in Settings", symbol: "location.slash", tint: JcTheme.amber)
                    } else if progress.revision == 0 {
                        chip("Finding GPS…", symbol: "location.magnifyingglass", tint: .white)
                    }
                }
                Spacer()
                VStack(spacing: 10) {
                    MapStyleButton(style: $style)
                    MapCircleButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left"
                                        : "arrow.up.left.and.arrow.down.right",
                                    label: expanded ? "Smaller map" : "Full-screen map") { expanded.toggle() }
                    if !following {
                        MapCircleButton(symbol: "location.fill", label: "Follow me") { following = true }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: following)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 0 : 22, bottomTrailingRadius: expanded ? 0 : 22))
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .jcLiquidGlass(in: Capsule())
    }

    // MARK: Numbers

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = workout.elapsed(at: context.date)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WorkoutLiveView.clock(elapsed))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(workout.phase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: elapsed)
                    Spacer()
                    if hasWearable { heartRate }
                }
                if hasWearable, workout.phase == .running,
                   let since = workout.lastTickAt.map({ context.date.timeIntervalSince($0) }), since > 5 {
                    Label("Waiting for the ring…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(JcTheme.amber)
                }
                if hasWearable { zones }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 18) {
                    stat("Distance", unit.distance(progress.distance), unit.symbol)
                    stat("Pace", unit.pace(secondsPerMeter: progress.pace.map { $0 / 1000 }), "/\(unit.symbol)")
                    stat("Avg pace", unit.pace(secondsPerMeter: progress.distance > 50 ? Double(elapsed) / progress.distance : nil),
                         "/\(unit.symbol)")
                    stat("Climbed", unit.elevation(progress.gain), unit.elevationSymbol)
                    stat("Calories", "\(Int(calories.rounded()))", "kcal")
                    stat("Steps", steps.map { $0.formatted() } ?? "--", cadence.map { "\($0) spm" })
                }
                if workout.heartRates.filter({ $0 > 0 }).count > 1 {
                    WorkoutTrace(heartRates: workout.heartRates)
                        .frame(height: 90)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
    }

    private var calories: Double {
        let ring = workout.tick?.kilocalories ?? 0
        return ring > 0 ? ring : progress.kilocalories
    }

    private var steps: Int? { workout.phoneOnly ? workout.phoneSteps : workout.tick?.steps }
    private var cadence: Int? { workout.phoneOnly ? workout.phoneCadence : workout.cadence }

    private var heartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RingMetricSymbol(name: "heart.fill", tint: RingMeasurementType.heartRate.tint,
                             pulsing: workout.phase == .running && workout.tick?.heartRate != nil, size: 18)
            Text(workout.tick?.heartRate.map(String.init) ?? "--")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("bpm").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var zones: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { zone in
                Capsule()
                    .fill(WorkoutLiveView.zoneTint(zone).opacity(workout.zone == zone ? 1 : 0.22))
                    .frame(height: 6)
            }
        }
        .animation(.snappy, value: workout.zone)
    }

    private func stat(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 44) {
            control(workout.phase == .paused ? "play.fill" : "pause.fill",
                    label: workout.phase == .paused ? "Resume" : "Pause", tint: JcTheme.amber, size: 72) {
                workout.phase == .paused ? workout.resume() : workout.pause()
            }
            .disabled(workout.phase == .ending)
            control("xmark", label: "End", tint: JcTheme.danger, size: 72) { confirmingEnd = true }
                .disabled(workout.phase == .ending)
        }
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    /// With the map full screen: time, distance and pace, and the buttons.
    private var strip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutLiveView.clock(workout.elapsed(at: context.date)))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(unit.distance(progress.distance)) \(unit.symbol) · \(unit.pace(secondsPerMeter: progress.pace.map { $0 / 1000 }))/\(unit.symbol)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                control(workout.phase == .paused ? "play.fill" : "pause.fill",
                        label: workout.phase == .paused ? "Resume" : "Pause", tint: JcTheme.amber, size: 54, caption: false) {
                    workout.phase == .paused ? workout.resume() : workout.pause()
                }
                control("xmark", label: "End", tint: JcTheme.danger, size: 54, caption: false) { confirmingEnd = true }
            }
            .padding(.horizontal, 22)
            .frame(height: 132)
        }
    }

    private func control(_ symbol: String, label: String, tint: Color, size: CGFloat, caption: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.33, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.16), in: Circle())
                    .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                if caption { Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
