import SwiftUI

/// What the workout picker is about to start.
enum WorkoutChoice: Hashable, Identifiable {
    case sport(RingSport)
    /// A strength workout, from a template or empty.
    case strength(WorkoutTemplate?)

    var id: String {
        switch self {
        case .sport(let sport): return "sport-\(sport.id)"
        case .strength(let template): return template.map { "template-\($0.id)" } ?? "strength-empty"
        }
    }

    static func == (a: WorkoutChoice, b: WorkoutChoice) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Picking the Strength tile is an empty strength workout.
    static func picked(_ sport: RingSport) -> WorkoutChoice {
        sport.id == RingSport.strengthID ? .strength(nil) : .sport(sport)
    }

    var isStrength: Bool { if case .strength = self { return true }; return false }
}

/// Something that will watch the workout, as the start screen lists it.
struct WorkoutMonitor: Identifiable, Equatable {
    enum Status: Equatable {
        /// Good to go, with what to know ("Connected · 82%").
        case ready(String)
        case connecting
        /// It won't be there; why, and what the workout does without it.
        case unavailable(String)
        /// Switched off by the person.
        case off(String)
    }

    var id: String
    var name: String
    var symbol: String
    /// What it records: "Heart rate, zones and calories".
    var tracks: String
    var status: Status

    /// The ring as the start screen needs to know it.
    struct Ring: Equatable {
        var paired: Bool
        var name: String
        var state: ConnectionState
        var battery: RingBattery?
        /// A connection is being made for this workout.
        var connecting: Bool
    }

    /// Who watches `choice`: the ring for heart rate, the iPhone for GPS or
    /// the rest timer, and Apple Health for keeping it.
    static func list(for choice: WorkoutChoice, ring: Ring, appleHealth: Bool) -> [WorkoutMonitor] {
        var out: [WorkoutMonitor] = []
        let strength = choice.isStrength
        let outdoor: Bool = { if case .sport(let sport) = choice { return sport.outdoor }; return false }()

        let ringTracks = strength ? "Heart rate through every set and rest, zones and calories"
            : "Time, heart rate and zones, steps, calories" + (outdoor ? "" : " and distance")
        let ringStatus: Status
        if !ring.paired {
            ringStatus = .unavailable(strength ? "No ring paired — sets are logged without heart rate."
                                               : "No ring paired — pair one in Devices to record this workout.")
        } else if case .ready = ring.state {
            if ring.battery?.charging == true {
                ringStatus = .unavailable("On its charger — take it off to record the workout.")
            } else {
                ringStatus = .ready(ring.battery.map { "Connected · \($0.percent)% battery" } ?? "Connected")
            }
        } else if ring.connecting || [.scanning, .connecting, .discovering].contains(ring.state) {
            ringStatus = .connecting
        } else {
            ringStatus = .unavailable(strength ? "Not in range — sets are logged without heart rate until it is."
                                               : "Not in range — bring it close; the workout waits for it.")
        }
        out.append(WorkoutMonitor(id: "ring", name: ring.paired ? ring.name : "Smart ring", symbol: "circle.circle",
                                  tracks: ringTracks, status: ringStatus))

        let phoneTracks = strength ? "Rest timer, alerts and the Lock Screen countdown"
            : outdoor ? "GPS distance and pace, and the Lock Screen timer" : "The Lock Screen and Dynamic Island timer"
        out.append(WorkoutMonitor(id: "phone", name: "iPhone", symbol: outdoor ? "location.fill" : "iphone",
                                  tracks: phoneTracks, status: .ready(outdoor ? "GPS on" : "Ready")))

        out.append(WorkoutMonitor(id: "health", name: "Apple Health", symbol: "heart.text.square.fill",
                                  tracks: "Keeps the workout with its heart rate and calories",
                                  status: appleHealth ? .ready("Saves when you finish")
                                                      : .off("Off — turn it on in Health settings")))
        return out
    }
}

/// Roughly how long a template takes: 40 s a set plus each exercise's rests.
enum TemplateEstimate {
    static func minutes(_ template: WorkoutTemplate, settings: (String) -> ExerciseSettings) -> Int {
        var seconds = 0
        for exercise in template.exercises {
            let s = settings(exercise.exerciseID)
            for set in exercise.sets {
                seconds += exercise.kind.usesSeconds ? max(40, set.seconds ?? 60) : 40
                seconds += set.tag == .warmup ? (s.warmupRestSeconds ?? 0) : (s.restSeconds ?? 120)
            }
        }
        return max(5, Int((Double(seconds) / 60 / 5).rounded()) * 5)
    }

    /// "3 sets · 8 reps · 60 kg", "3 sets · 8–10 reps · 60–65 kg", "2 sets · 1:00".
    static func summary(_ exercise: LoggedExercise, unit: TrainingUnit) -> String {
        let working = exercise.sets.filter { $0.tag != .warmup }
        let warmups = exercise.sets.count - working.count
        var parts = ["\(working.count) set\(working.count == 1 ? "" : "s")"]
        func span(_ values: [Double], _ text: (Double) -> String) -> String? {
            guard let lo = values.min(), let hi = values.max() else { return nil }
            return lo == hi ? text(lo) : "\(text(lo))–\(text(hi))"
        }
        if exercise.kind.usesReps, let reps = span(working.compactMap { $0.reps.map(Double.init) }, { String(Int($0)) }) {
            parts.append("\(reps) reps")
        }
        if exercise.kind.usesWeight, let kg = span(working.compactMap(\.kg), { unit.format($0) }) {
            parts.append("\(kg) \(unit.symbol)")
        }
        if exercise.kind.usesSeconds, let time = span(working.compactMap { $0.seconds.map(Double.init) }, { SetRow.clock(Int($0)) }) {
            parts.append(time)
        }
        if warmups > 0 { parts.append("+\(warmups) warm-up\(warmups == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Before any workout starts: what it is, what will watch it, and Start.
struct WorkoutConfirmView: View {
    let choice: WorkoutChoice
    @ObservedObject var store: TrainingStore
    let library: ExerciseLibrary
    /// Stand-ins for the live wearables (previews and render tests).
    var monitors: [WorkoutMonitor]? = nil
    let onStart: (WorkoutChoice) -> Void
    @ObservedObject private var ring: RingManager
    @ObservedObject private var ringSession: RingSession
    @ObservedObject private var appleHealth = AppleHealthWriter.shared
    @State private var connecting = false
    @State private var editing = false

    init(choice: WorkoutChoice, store: TrainingStore = .shared, library: ExerciseLibrary = .shared,
         monitors: [WorkoutMonitor]? = nil, ring: RingManager = WearablesHub.shared.ring,
         onStart: @escaping (WorkoutChoice) -> Void) {
        self.choice = choice
        self.store = store
        self.library = library
        self.monitors = monitors
        self.onStart = onStart
        _ring = ObservedObject(wrappedValue: ring)
        _ringSession = ObservedObject(wrappedValue: ring.session)
    }

    /// The template as saved now (it may have been edited from here).
    private var template: WorkoutTemplate? {
        guard case .strength(let t?) = choice else { return nil }
        return store.templates.first { $0.id == t.id } ?? t
    }

    private var ringPaired: Bool { WearableIdentity.remembered(WearableKeepAlive.ring) != nil }

    private var liveMonitors: [WorkoutMonitor] {
        monitors ?? WorkoutMonitor.list(
            for: choice,
            ring: .init(paired: ringPaired, name: WearableNames.shared.name(WearableKeepAlive.ring, fallback: "Colmi R12"),
                        state: ring.state, battery: ringSession.battery, connecting: connecting),
            appleHealth: appleHealth.enabled && appleHealth.isAuthorized)
    }

    private var title: String {
        switch choice {
        case .sport(let sport): return sport.name
        case .strength: return template?.name ?? "Strength"
        }
    }

    private var symbol: String {
        switch choice {
        case .sport(let sport): return sport.symbol
        case .strength: return RingSport.withID(RingSport.strengthID).symbol
        }
    }

    private var subtitle: String {
        switch choice {
        case .sport(let sport): return sport.outdoor ? "Outdoor · GPS" : "Indoor"
        case .strength:
            guard let template else { return "Empty workout" }
            let sets = template.exercises.reduce(0) { $0 + $1.sets.filter { $0.tag != .warmup }.count }
            let minutes = TemplateEstimate.minutes(template) { store.settings(for: $0) }
            return "\(template.exercises.count) exercise\(template.exercises.count == 1 ? "" : "s") · \(sets) sets · about \(minutes) min"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                monitoring
                preview
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .jcScreen()
        .toolbar {
            if template != nil {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { startButton }
        .sheet(isPresented: $editing) {
            if let template { TemplateEditor(template: template, store: store, library: library) }
        }
        .task { await connectRing() }
    }

    /// Bring the ring up while the person reads, so Start is instant.
    private func connectRing() async {
        guard monitors == nil, ringPaired else { return }
        if case .ready = ring.state { return }
        connecting = true
        _ = await ring.ensureConnected(timeout: 12)
        connecting = false
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .frame(width: 68, height: 68)
                .background(JcTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let template, let last = store.lastPerformed(templateID: template.id) {
                    Text("Last done \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Monitoring

    private var monitoring: some View {
        let list = liveMonitors
        return CardGroup("Monitoring") {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, monitor in
                if index > 0 { RowDivider() }
                Row(minHeight: 64) {
                    HStack(alignment: .top, spacing: 12) {
                        JcIcon(monitor.symbol, size: 16, weight: .semibold)
                            .foregroundStyle(tint(monitor.status))
                            .frame(width: 34, height: 34)
                            .background(tint(monitor.status).opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(monitor.name).font(.body.weight(.semibold))
                                Spacer(minLength: 6)
                                statusLabel(monitor.status)
                            }
                            Text(monitor.tracks)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if case .unavailable(let why) = monitor.status {
                                Text(why)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(JcTheme.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func tint(_ status: WorkoutMonitor.Status) -> Color {
        switch status {
        case .ready: return JcTheme.success
        case .connecting: return JcTheme.accent
        case .unavailable: return JcTheme.amber
        case .off: return JcTheme.muted
        }
    }

    @ViewBuilder private func statusLabel(_ status: WorkoutMonitor.Status) -> some View {
        switch status {
        case .ready(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(JcTheme.success)
                .lineLimit(1)
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption.weight(.semibold)).foregroundStyle(JcTheme.accent)
            }
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(JcTheme.amber)
        case .off(let text):
            Text(text.components(separatedBy: " — ").first ?? text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(JcTheme.muted)
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        switch choice {
        case .sport(let sport): sportPreview(sport)
        case .strength:
            if let template { templatePreview(template) } else { emptyStrengthPreview }
        }
    }

    private func sportPreview(_ sport: RingSport) -> some View {
        let items: [(String, String)] = [
            ("timer", "Time"), ("heart.fill", "Heart rate zones"), ("flame.fill", "Calories"),
            ("figure.walk", "Steps & cadence"),
            (sport.outdoor ? "location.fill" : "point.topleft.down.to.point.bottomright.curvepath",
             sport.outdoor ? "GPS distance" : "Distance"),
        ] + (sport.outdoor ? [("speedometer", "Pace")] : [("waveform.path.ecg", "Heart-rate trace")])
        return CardGroup("What's recorded", footer: "A 3-second countdown, then the ring starts the session. Pause and End are on the live screen.") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 14) {
                ForEach(items, id: \.1) { symbol, label in
                    Label(label, systemImage: symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.hierarchical)
                        .labelStyle(TintedIconLabel())
                }
            }
            .padding(16)
        }
    }

    private func templatePreview(_ template: WorkoutTemplate) -> some View {
        CardGroup("Exercises", footer: template.note.isEmpty ? nil : template.note) {
            ForEach(Array(template.exercises.enumerated()), id: \.element.id) { index, exercise in
                if index > 0 { RowDivider() }
                Row(minHeight: 60) {
                    HStack(spacing: 12) {
                        if let group = exercise.superset {
                            Capsule().fill(SupersetTint.color(group)).frame(width: 3, height: 36)
                        }
                        ExerciseThumbnail(exercise: library.exercise(exercise.exerciseID, custom: store.customExercises,
                                                                     settings: store.settings), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(TemplateEstimate.summary(exercise, unit: TrainingUnit.current))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var emptyStrengthPreview: some View {
        CardGroup("Exercises", footer: "Add exercises once you start; save the workout as a template at the end to start it in one tap next time.") {
            CardEmptyBlock("You'll add exercises as you go.", symbol: "plus.circle")
        }
    }

    // MARK: Start

    private var startButton: some View {
        Button { onStart(choice) } label: {
            Label(template.map { "Start \($0.name)" } ?? "Start", systemImage: "play.fill")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(.black)
                .background(JcTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(JcTheme.bg.opacity(0.92).ignoresSafeArea(edges: .bottom))
        .accessibilityHint("Starts the workout now")
    }
}

/// An icon in the accent beside plain text.
private struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(JcTheme.accent).frame(width: 22)
            configuration.title
        }
    }
}
