import Charts
import SwiftUI

// MARK: - Picker

/// Choose a sport and go: the common eight as a grid (the last one used
/// first), everything else under More. Picking one starts it.
struct WorkoutPicker: View {
    let onPick: (RingSport) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jc.workout.lastSport") private var lastSport = 7

    private var common: [RingSport] {
        let last = RingSport.withID(lastSport)
        return [last] + RingSport.common.filter { $0.id != last.id }.prefix(RingSport.common.count - 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(common) { sport in tile(sport) }
                    }
                    .padding(.horizontal, 16)
                    CardGroup("More") {
                        ForEach(Array(RingSport.more.enumerated()), id: \.element.id) { index, sport in
                            if index > 0 { RowDivider() }
                            Button { pick(sport) } label: {
                                Row(minHeight: 50) {
                                    HStack(spacing: 14) {
                                        Image(systemName: sport.symbol)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(JcTheme.accent)
                                            .frame(width: 28)
                                        Text(sport.name)
                                        Spacer()
                                        if sport.outdoor { gpsBadge }
                                    }
                                    .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .jcScreen("Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func tile(_ sport: RingSport) -> some View {
        Button { pick(sport) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: sport.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(JcTheme.accent)
                        .frame(width: 34, height: 32, alignment: .leading)
                    Spacer()
                    if sport.outdoor { gpsBadge }
                }
                Text(sport.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 104)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(sport.name)")
    }

    private var gpsBadge: some View {
        Text("GPS")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func pick(_ sport: RingSport) {
        lastSport = sport.id
        dismiss()
        onPick(sport)
    }
}

// MARK: - Live

/// A workout under way, full screen: the time big, heart rate in its zone,
/// steps, calories and distance, with Pause and End within a thumb's reach.
struct WorkoutLiveView: View {
    @ObservedObject var workout: RingWorkoutController
    @State private var confirmingEnd = false

    var body: some View {
        ZStack {
            JcTheme.bg.ignoresSafeArea()
            switch workout.phase {
            case .countdown(let n):
                countdown(n)
            case .starting:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Starting on your ring…").foregroundStyle(.secondary)
                }
            case .running, .paused, .ending:
                live
            case .failed(let why):
                failed(why)
            case .finished(let result):
                WorkoutSummaryView(workout: result, onSave: { workout.close(save: true) },
                                   onDiscard: { workout.close(save: false) })
            case .idle:
                EmptyView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func countdown(_ n: Int) -> some View {
        VStack(spacing: 18) {
            Text(workout.sport?.name ?? "Workout")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(n)")
                .font(.system(size: 140, weight: .bold, design: .rounded))
                .foregroundStyle(JcTheme.accent)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: n)
            Button("Cancel") { workout.cancelCountdown() }
                .buttonStyle(.jcGlass(tint: JcTheme.danger))
        }
    }

    private var live: some View {
        let tick = workout.tick
        return VStack(spacing: 26) {
            HStack(spacing: 10) {
                Image(systemName: workout.sport?.symbol ?? "figure.mixed.cardio")
                    .foregroundStyle(JcTheme.accent)
                Text(workout.sport?.name ?? "Workout").font(.headline)
                if workout.phase == .paused {
                    Text("PAUSED")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(JcTheme.amber)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(JcTheme.amber.opacity(0.15), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Text(Self.clock(tick?.elapsed ?? 0))
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(workout.phase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: tick?.elapsed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            heartRate(tick)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                stat("Steps", tick.map { $0.steps.formatted() } ?? "--",
                     workout.cadence.map { "\($0) spm" }, symbol: "figure.walk")
                stat("Calories", tick.map { "\(Int($0.kilocalories.rounded()))" } ?? "--", "kcal", symbol: "flame.fill")
                stat("Distance", distance, workout.gpsDistance == nil ? "km · ring" : "km · GPS", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                if workout.sport?.outdoor == true {
                    stat("Pace", workout.pace.map(Self.pace) ?? "--", "/km", symbol: "speedometer")
                } else {
                    stat("Average", averageHeartRate.map(String.init) ?? "--", "bpm", symbol: "heart.text.square")
                }
            }
            .padding(.horizontal, 24)

            trace
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            HStack(spacing: 40) {
                controlButton(workout.phase == .paused ? "play.fill" : "pause.fill",
                              label: workout.phase == .paused ? "Resume" : "Pause", tint: JcTheme.amber) {
                    workout.phase == .paused ? workout.resume() : workout.pause()
                }
                .disabled(workout.phase == .ending)
                controlButton("xmark", label: "End", tint: JcTheme.danger) { confirmingEnd = true }
                    .disabled(workout.phase == .ending)
            }
            .padding(.bottom, 28)
        }
        .confirmationDialog("End workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End workout", role: .destructive) { workout.end() }
            Button("Keep going", role: .cancel) {}
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: workout.phase)
    }

    private var averageHeartRate: Int? {
        let readings = workout.heartRates.filter { $0 > 0 }
        return readings.isEmpty ? nil : readings.reduce(0, +) / readings.count
    }

    /// Heart rate across the workout so far.
    @ViewBuilder private var trace: some View {
        if workout.heartRates.filter({ $0 > 0 }).count > 1 {
            WorkoutTrace(heartRates: workout.heartRates)
                .frame(height: 110)
                .accessibilityHidden(true)
        }
    }

    private var distance: String {
        let meters = workout.gpsDistance ?? workout.tick.map { Double($0.distanceMeters) }
        return meters.map { String(format: "%.2f", $0 / 1000) } ?? "--"
    }

    private func heartRate(_ tick: RingSportTick?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RingMetricSymbol(name: "heart.fill", tint: RingMeasurementType.heartRate.tint,
                                 pulsing: workout.phase == .running && tick?.heartRate != nil, size: 22)
                Text(tick?.heartRate.map(String.init) ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: tick?.heartRate)
                Text("bpm").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if let zone = workout.zone {
                    Text("Zone \(zone)")
                        .font(.headline)
                        .foregroundStyle(Self.zoneTint(zone))
                }
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { zone in
                    Capsule()
                        .fill(Self.zoneTint(zone).opacity(workout.zone == zone ? 1 : 0.22))
                        .frame(height: 8)
                }
            }
            .animation(.snappy, value: workout.zone)
        }
        .padding(.horizontal, 24)
    }

    private func stat(_ label: String, _ value: String, _ unit: String?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlButton(_ symbol: String, label: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 84, height: 84)
                    .background(tint.opacity(0.16), in: Circle())
                    .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func failed(_ why: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(JcTheme.amber)
            Text(why)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 14) {
                Button("Close") { workout.close(save: false) }
                    .buttonStyle(.jcGlass(tint: .secondary))
                if let sport = workout.sport {
                    Button("Try again") { workout.close(save: false); workout.start(sport) }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent))
                }
            }
        }
    }

    // MARK: Formatting

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        let s = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Zones in the app's tokens, calm to hard.
    static func zoneTint(_ zone: Int) -> Color {
        switch zone {
        case 1: return JcTheme.blue
        case 2: return JcTheme.accent
        case 3: return JcTheme.success
        case 4: return JcTheme.amber
        default: return JcTheme.danger
        }
    }
}

// MARK: - Summary

/// The workout, done: how long, how hard, what it counted — saved to
/// Jarvis Health unless discarded.
struct WorkoutSummaryView: View {
    let workout: RingWorkout
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(workout.sportName, systemImage: RingSport.withID(workout.sport).symbol)
                        .font(.headline)
                        .foregroundStyle(JcTheme.accent)
                    Text(WorkoutLiveView.clock(workout.activeSeconds))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(workout.start.formatted(date: .abbreviated, time: .shortened)) – \(workout.end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 44)

                CardGroup("Summary") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 16) {
                        item("Average heart rate", workout.heartRateAverage.map { "\($0) bpm" })
                        item("Max heart rate", workout.heartRateMax.map { "\($0) bpm" })
                        item("Calories", "\(Int(workout.kilocalories.rounded())) kcal")
                        item("Steps", workout.steps.formatted())
                        item("Distance", String(format: "%.2f km", workout.distanceMeters / 1000)
                             + (workout.distanceSource == "gps" ? " · GPS" : ""))
                        item("Cadence", workout.activeSeconds >= 60
                             ? "\(Int(Double(workout.steps) / (Double(workout.activeSeconds) / 60))) spm" : nil)
                    }
                    .padding(16)
                }

                if workout.heartRates.contains(where: { $0 > 0 }) {
                    CardGroup("Heart rate") {
                        Chart {
                            ForEach(Array(workout.heartRates.enumerated()), id: \.offset) { index, bpm in
                                if bpm > 0 {
                                    LineMark(x: .value("Minute", Double(index * 5) / 60), y: .value("bpm", bpm))
                                        .foregroundStyle(RingMeasurementType.heartRate.tint)
                                        .interpolationMethod(.catmullRom)
                                }
                            }
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartXAxis {
                            AxisMarks { value in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                                AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0))m") }
                            }
                        }
                        .frame(height: 150)
                        .padding(14)
                    }
                }

                CardGroup("Heart-rate zones") {
                    VStack(spacing: 10) {
                        ForEach((1...5).reversed(), id: \.self) { zone in
                            let seconds = workout.zoneSeconds[zone - 1]
                            let total = max(1, workout.zoneSeconds.reduce(0, +))
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

                if onSave != nil || onDiscard != nil {
                    HStack(spacing: 14) {
                        if let onDiscard {
                            Button("Discard", action: onDiscard)
                                .buttonStyle(.jcGlass(tint: .secondary))
                        }
                        if let onSave {
                            Button("Save to Health", action: onSave)
                                .buttonStyle(.jcGlass(tint: JcTheme.accent))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func item(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
}

// MARK: - Presenting

/// Puts a running workout full screen over whichever screen started it.
struct RingWorkoutPresenter: ViewModifier {
    @ObservedObject var workout: RingWorkoutController

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { workout.isPresenting }, set: { _ in })) {
            WorkoutLiveView(workout: workout)
        }
    }
}

// MARK: - A day's workouts

/// The workouts on a Health-tab day; each opens its summary.
struct HealthWorkoutsCard: View {
    let workouts: [RingWorkout]
    @State private var open: RingWorkout?

    var body: some View {
        CardGroup("Workouts") {
            ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                if index > 0 { RowDivider() }
                Button { open = workout } label: {
                    Row(minHeight: 58) {
                        HStack(spacing: 12) {
                            Image(systemName: RingSport.withID(workout.sport).symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(JcTheme.accent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workout.sportName).font(.body.weight(.medium))
                                Text(workout.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(WorkoutLiveView.clock(workout.activeSeconds))
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                Text([workout.heartRateAverage.map { "\($0) bpm" },
                                      "\(Int(workout.kilocalories.rounded())) kcal"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $open) { workout in
            WorkoutSummaryView(workout: workout)
                .background(JcTheme.bg)
                .presentationDetents([.large])
        }
    }
}

/// A workout's heart rate as a filled trace, fitted to its own range — the
/// shape is the point, not the distance from zero.
struct WorkoutTrace: View {
    let heartRates: [Int]

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let bpm: Double
    }

    private var points: [Point] {
        heartRates.enumerated().compactMap { index, bpm in
            bpm > 0 ? Point(id: index, minute: Double(index * 5) / 60, bpm: Double(bpm)) : nil
        }
    }

    var body: some View {
        let points = points
        let floor = max(40, (points.map(\.bpm).min() ?? 60) - 12)
        let ceiling = (points.map(\.bpm).max() ?? 160) + 8
        let tint = RingMeasurementType.heartRate.tint
        let fill = LinearGradient(colors: [tint.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
        return Chart(points) { point in
            AreaMark(x: .value("Minute", point.minute), yStart: .value("Floor", floor), yEnd: .value("bpm", point.bpm))
                .foregroundStyle(fill)
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Minute", point.minute), y: .value("bpm", point.bpm))
                .foregroundStyle(tint)
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: floor...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
    }
}
