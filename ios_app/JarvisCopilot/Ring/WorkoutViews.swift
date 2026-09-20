import Charts
import SwiftUI

// MARK: - Picker

/// Choose a sport and go: strength templates first, the common eight as a
/// grid (the last one used first), everything else under More. Picking one
/// starts it.
struct WorkoutPicker: View {
    let onPick: (RingSport) -> Void
    /// Start a strength template (nil hides the Templates row).
    var onTemplate: ((WorkoutTemplate) -> Void)?
    @ObservedObject var store: TrainingStore
    let library: ExerciseLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jc.workout.lastSport") private var lastSport = 7
    @State private var sheet: TemplateSheet?
    /// The workout being confirmed: every start goes through its screen.
    @State private var choice: WorkoutChoice?

    private enum TemplateSheet: Identifiable {
        case edit(WorkoutTemplate), new, manage
        var id: String {
            switch self {
            case .edit(let t): return "edit-\(t.id)"
            case .new: return "new"
            case .manage: return "manage"
            }
        }
    }

    init(store: TrainingStore = .shared, library: ExerciseLibrary = .shared,
         onTemplate: ((WorkoutTemplate) -> Void)? = nil, onPick: @escaping (RingSport) -> Void) {
        self.store = store
        self.library = library
        self.onTemplate = onTemplate
        self.onPick = onPick
    }

    private var common: [RingSport] {
        let last = RingSport.withID(lastSport)
        return [last] + RingSport.common.filter { $0.id != last.id }.prefix(RingSport.common.count - 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let onTemplate {
                        TemplatesRow(store: store,
                                     onStart: { choice = .strength($0) },
                                     onEdit: { sheet = .edit($0) },
                                     onNew: { sheet = .new },
                                     onManage: { sheet = .manage })
                    }
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
            .navigationDestination(item: $choice) { picked in
                WorkoutConfirmView(choice: picked, store: store, library: library) { start($0) }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .edit(let template): TemplateEditor(template: template, store: store, library: library)
                case .new: TemplateEditor(template: nil, store: store, library: library)
                case .manage: TemplatesManager(store: store, library: library)
                }
            }
            .task { if onTemplate != nil { await store.refresh() } }
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
        choice = .picked(sport)
    }

    /// Confirmed: the picker closes and the workout begins.
    private func start(_ choice: WorkoutChoice) {
        dismiss()
        switch choice {
        case .sport(let sport):
            lastSport = sport.id
            onPick(sport)
        case .strength(let template?):
            lastSport = RingSport.strengthID
            if let onTemplate { onTemplate(store.templates.first { $0.id == template.id } ?? template) }
        case .strength(nil):
            lastSport = RingSport.strengthID
            onPick(RingSport.withID(RingSport.strengthID))
        }
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
                if let strength = workout.strength {
                    StrengthLiveView(workout: workout, session: strength)
                } else if workout.sport?.outdoor == true {
                    RouteLiveView(workout: workout)
                } else {
                    live
                }
            case .failed(let why):
                failed(why)
            case .finished(let result):
                if result.isStrength {
                    StrengthSummaryView(workout: result, store: workout.strengthStore,
                                        onSave: { workout.close(save: true) },
                                        onDiscard: { workout.close(save: false) })
                } else if result.route != nil || RingSport.withID(result.sport).outdoor {
                    // Every outdoor workout ends on its map — with a word on why
                    // when GPS couldn't draw a route.
                    RouteDetailView(workout: result, route: workout.finishedRoute, note: workout.routeNote,
                                    onSave: { workout.close(save: true) }, onDiscard: { workout.close(save: false) })
                } else {
                    WorkoutSummaryView(workout: result, onSave: { workout.close(save: true) },
                                       onDiscard: { workout.close(save: false) })
                }
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

            // The ring reports once a second; between reports the phone's
            // clock carries on, and a long silence says so instead of freezing.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let since = workout.lastTickAt.map { context.date.timeIntervalSince($0) } ?? 0
                let running = workout.phase == .running
                let shown = workout.elapsed(at: context.date)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.clock(shown))
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(workout.phase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: shown)
                    if running, since > 5 {
                        Label("Waiting for the ring…", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(JcTheme.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            }

            heartRate(tick)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                // The ring's steps, or the phone's when the ring (a hand on a
                // rail) counted fewer.
                stat("Steps", workout.stepCount.map { $0.formatted() } ?? "--",
                     workout.stepCadence.map { "\($0) spm" }, symbol: "figure.walk")
                stat("Calories", tick.map { "\(Int($0.kilocalories.rounded()))" } ?? "--", "kcal", symbol: "flame.fill")
                if workout.sport?.id == 80, let floors = workout.floors {
                    stat("Floors", floors.formatted(), "climbed", symbol: "figure.stair.stepper")
                } else {
                    stat("Distance", distance, distanceNote, symbol: "point.topleft.down.to.point.bottomright.curvepath")
                }
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
        let meters = workout.gpsDistance ?? workout.indoorDistance ?? workout.tick.map { Double($0.distanceMeters) }
        return meters.map { DistanceUnit.current.distance($0) } ?? "--"
    }

    /// "mi · ring", "km · phone", "mi · GPS": the unit and where it came from.
    private var distanceNote: String {
        let source = workout.gpsDistance != nil ? "GPS" : workout.indoorDistance != nil ? "phone" : "ring"
        return "\(DistanceUnit.current.symbol) · \(source)"
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
                    Button("Try again") {
                        // The same workout again: the route it was following too.
                        let guide = workout.guide
                        workout.close(save: false)
                        workout.guide = guide
                        workout.start(sport)
                    }
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
    /// Pushed from the Health tab: it can be deleted from here.
    var fromHistory = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

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
                // Room under the sheet's grabber; a pushed page has its bar.
                .padding(.top, onSave == nil ? 8 : 44)

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

                WorkoutZonesCard(zoneSeconds: workout.zoneSeconds)

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
        .toolbar { if fromHistory { options } }
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                WorkoutEditing.delete(workout)
                dismiss()
            }
        } message: {
            Text("It goes from Jarvis Health and Apple Health.")
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

    /// Delete, from the Health tab's copy of it.
    @ToolbarContentBuilder private var options: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Workout options")
        }
    }
}

// MARK: - Presenting

/// The workout as a sheet over whichever screen started it. Drag it down and
/// the workout carries on (the Health tab's card brings it back); a summary
/// swiped away is saved, a failure closed.
struct RingWorkoutPresenter: ViewModifier {
    @ObservedObject var workout: RingWorkoutController

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { workout.showsLive && workout.isPresenting },
            set: { shown in
                guard !shown else { return }
                switch workout.phase {
                case .finished: workout.close(save: true)
                case .failed: workout.close(save: false)
                default: workout.showsLive = false
                }
            })) {
            WorkoutLiveView(workout: workout)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(JcTheme.bg)
                .presentationCornerRadius(34)
        }
    }
}

/// On the Health tab while a workout runs: its sport, time, heart rate and
/// distance live, and a tap back into the workout.
struct WorkoutInProgressCard: View {
    @ObservedObject var workout: RingWorkoutController

    var body: some View {
        if workout.isActive, let sport = workout.sport {
            CardGroup("Workout") {
                Button { workout.showsLive = true } label: {
                    Row(minHeight: 76) {
                        HStack(spacing: 14) {
                            RingMetricSymbol(name: sport.symbol, tint: JcTheme.accent,
                                             pulsing: workout.phase == .running, size: 22)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                if let strength = workout.strength {
                                    StrengthNameLine(session: strength)
                                } else {
                                    Text(workout.phase == .paused ? "\(sport.name) · Paused" : sport.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(workout.phase == .paused ? AnyShapeStyle(JcTheme.amber) : AnyShapeStyle(.secondary))
                                }
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(WorkoutLiveView.clock(workout.elapsed(at: context.date)))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                if let hr = workout.tick?.heartRate {
                                    Label("\(hr)", systemImage: "heart.fill")
                                        .foregroundStyle(RingMeasurementType.heartRate.tint)
                                }
                                let meters = workout.gpsDistance ?? workout.tick.map { Double($0.distanceMeters) }
                                if let meters, meters > 0 {
                                    Text(String(format: "%.2f km", meters / 1000)).foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A strength workout's name as it is typed (the controller does not
/// republish its session's edits).
private struct StrengthNameLine: View {
    @ObservedObject var session: StrengthSession

    var body: some View {
        Text(session.log.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - A day's workouts

/// Workouts, one row each, opening its summary: a day's on the Health tab
/// (with Start when there are none, and Show all into the exercise history),
/// or a range's in that history, dated.
struct HealthWorkoutsCard: View {
    let workouts: [RingWorkout]
    /// Rows show distance in it: redrawn when it changes in Settings.
    @AppStorage("jc.distance.unit") private var distanceUnit = DistanceUnit.current.rawValue
    var title = "Workouts"
    /// Rows across several days say which day.
    var showsDate = false
    var onStart: (() -> Void)?
    var showAll: (() -> Void)?

    var body: some View {
        CardGroup(title) {
            if workouts.isEmpty {
                Row(minHeight: 58) {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 30)
                        Text("No workouts").foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let onStart {
                            Button("Start", action: onStart)
                                .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                                .fixedSize()
                        }
                    }
                }
            }
            ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                if index > 0 { RowDivider() }
                // Pushed, with a back button, on the Health tab's stack.
                NavigationLink {
                    if workout.isStrength {
                        StrengthWorkoutDetail(workout: workout)
                    } else if workout.route != nil {
                        RouteDetailView(workout: workout, fromHistory: true)
                            .navigationTitle(workout.sportName)
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        WorkoutSummaryView(workout: workout, fromHistory: true)
                            .background(JcTheme.bg)
                            .navigationTitle(workout.sportName)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                } label: {
                    Row(minHeight: 58) {
                        HStack(spacing: 12) {
                            if let preview = workout.route?.preview, !preview.isEmpty {
                                RouteThumbnail(preview: preview, size: 40)
                            } else {
                                Image(systemName: RingSport.withID(workout.sport).symbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(JcTheme.accent)
                                    .frame(width: 30)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workout.sportName).font(.body.weight(.medium))
                                Text(showsDate
                                     ? workout.start.formatted(.dateTime.weekday(.abbreviated).day()) + " · "
                                        + workout.start.formatted(date: .omitted, time: .shortened)
                                     : workout.start.formatted(date: .omitted, time: .shortened))
                                    .lineLimit(1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(WorkoutLiveView.clock(workout.activeSeconds))
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                Text(Self.detail(workout))
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
            if let showAll {
                RowDivider()
                ShowAllRow(action: showAll)
            }
        }
    }
}

extension HealthWorkoutsCard {
    /// "5,230 kg · 18 sets" for a lift; "3.15 mi · 7:39/mi" outdoors; "132 bpm · 310 kcal" for the rest.
    static func detail(_ workout: RingWorkout) -> String {
        if let route = workout.route, route.distanceMeters > 0 {
            let unit = DistanceUnit.current
            let pace = route.movingSeconds > 0 ? Double(route.movingSeconds) / route.distanceMeters : nil
            return "\(unit.distance(route.distanceMeters)) \(unit.symbol) · \(unit.pace(secondsPerMeter: pace))/\(unit.symbol)"
        }
        if let log = workout.strength {
            let unit = TrainingUnit.current
            return "\(Int(unit.show(log.volumeKg).rounded()).formatted()) \(unit.symbol) · \(log.sets == 1 ? "1 set" : "\(log.sets) sets")"
        }
        return [workout.heartRateAverage.map { "\($0) bpm" }, "\(Int(workout.kilocalories.rounded())) kcal"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A workout's heart rate as a filled trace, fitted to its own range — the
/// shape is the point, not the distance from zero. The time axis spans the
/// whole width from the first second: the line grows left to right across
/// the first ten minutes, then the axis widens with the workout, and the
/// live reading pulses at the line's end.
struct WorkoutTrace: View {
    let heartRates: [Int]
    /// The width the axis starts at, in minutes.
    var window: Double = 10

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

    /// Minutes the axis covers: the window, or the workout once it is longer.
    static func span(samples: Int, window: Double) -> Double {
        max(window, Double(max(0, samples - 1) * 5) / 60)
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
        .chartXScale(domain: 0...Self.span(samples: heartRates.count, window: window))
        .chartYScale(domain: floor...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let last = points.last, let frame = proxy.plotFrame,
                   let x = proxy.position(forX: last.minute), let y = proxy.position(forY: last.bpm) {
                    let origin = geometry[frame].origin
                    LivePulseDot(tint: tint)
                        .position(x: origin.x + x, y: origin.y + y)
                }
            }
        }
    }
}

/// The live reading at the end of a trace: a dot with a ring breathing out of it.
struct LivePulseDot: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.35))
                .frame(width: 22, height: 22)
                .scaleEffect(out ? 1 : 0.35)
                .opacity(out ? 0 : 0.9)
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(JcTheme.bg, lineWidth: 1.5))
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { out = true }
        }
    }
}
