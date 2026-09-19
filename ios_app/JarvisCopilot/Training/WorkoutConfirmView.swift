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

    /// Recorded by GPS: it can run on the phone alone.
    var isOutdoor: Bool { if case .sport(let sport) = self { return sport.outdoor }; return false }

    /// "Run", "Walk" — or "Strength".
    var sportName: String {
        if case .sport(let sport) = self { return sport.name }
        return "Strength"
    }
}

/// Which wearable tracks workouts, as the person chose it on the start
/// screen (nothing is picked or connected for them).
enum WorkoutMonitorPreference {
    private static let key = "jc.workout.monitor"

    /// The ring, unless "No wearable" was chosen.
    static var usesRing: Bool {
        get { UserDefaults.standard.string(forKey: key) != "none" }
        set { UserDefaults.standard.set(newValue ? "ring" : "none", forKey: key) }
    }
}

/// Something that will watch the workout, as the start screen lists it.
struct WorkoutMonitor: Identifiable, Equatable {
    enum Status: Equatable {
        /// Good to go; the short value on the right ("82%", "GPS", "On").
        case ready(String)
        /// Known but not connected yet — Start (or Connect) brings it up.
        case idle(String)
        case connecting
        /// It won't be there: a short label, and a sentence for the footnote.
        case problem(String, note: String)
        /// Switched off by the person.
        case off(String)
    }

    var id: String
    var name: String
    var symbol: String
    var status: Status
    /// The ring's battery, drawn as a battery beside its percentage.
    var battery: Int? = nil

    /// The ring as the start screen needs to know it.
    struct Ring: Equatable {
        var paired: Bool
        var name: String
        var state: ConnectionState
        var battery: RingBattery?
        /// A connection is being made for this workout.
        var connecting: Bool
    }

    /// Who watches `choice`: the chosen wearable for heart rate, the iPhone
    /// for GPS or the rest timer, and Apple Health for keeping it.
    static func list(for choice: WorkoutChoice, ring: Ring, ringChosen: Bool = true, appleHealth: Bool) -> [WorkoutMonitor] {
        let strength = choice.isStrength
        let outdoor = choice.isOutdoor

        var ringMonitor = WorkoutMonitor(id: "ring", name: ring.paired ? ring.name : "Ring", symbol: "circle.circle",
                                         status: .connecting)
        if !ringChosen {
            ringMonitor.name = "No wearable"
            ringMonitor.symbol = "circle.dashed"
            ringMonitor.status = strength || outdoor
                ? .idle("Heart rate off")
                : .problem("None chosen", note: "A \(choice.sportName.lowercased()) is recorded by the ring — choose it to start.")
        } else if !ring.paired {
            ringMonitor.status = .problem("Not paired", note: strength
                ? "No ring is paired, so sets are logged without heart rate."
                : outdoor ? "No ring is paired — choose No wearable to record it by GPS alone."
                : "Pair a ring in Devices to record this workout.")
        } else if case .ready = ring.state {
            if ring.battery?.charging == true {
                ringMonitor.status = .problem("Charging", note: "Take the ring off its charger to record the workout.")
            } else if let battery = ring.battery {
                ringMonitor.status = .ready("\(battery.percent)%")
                ringMonitor.battery = battery.percent
            } else {
                ringMonitor.status = .ready("Connected")
            }
        } else if ring.connecting || [.scanning, .connecting, .discovering].contains(ring.state) {
            ringMonitor.status = .connecting
        } else if case .failed = ring.state {
            ringMonitor.status = .problem("Not in range", note: strength
                ? "Heart rate starts once the ring connects; sets are logged either way."
                : outdoor ? "Bring the ring close and reconnect, or choose No wearable to go by GPS alone."
                : "Bring the ring close and reconnect — the workout needs it to start.")
        } else {
            ringMonitor.status = .idle("Not connected")
        }

        return [
            ringMonitor,
            WorkoutMonitor(id: "phone", name: "iPhone", symbol: "iphone",
                           status: .ready(strength ? "Rest timer" : outdoor ? "GPS" : "Timer")),
            WorkoutMonitor(id: "health", name: "Apple Health", symbol: "heart.text.square",
                           status: appleHealth ? .ready("On") : .off("Off")),
        ]
    }

    /// A ring workout can't start without a ring; strength can, and so can
    /// an outdoor one with no wearable (the phone's GPS records it).
    static func canStart(_ choice: WorkoutChoice, ringChosen: Bool, ringPaired: Bool) -> Bool {
        choice.isStrength || (choice.isOutdoor && !ringChosen) || (ringChosen && ringPaired)
    }

    /// The sentences behind every problem, for the section's footnote.
    static func notes(_ list: [WorkoutMonitor]) -> String? {
        let notes = list.compactMap { monitor -> String? in
            if case .problem(_, let note) = monitor.status { return note }
            return nil
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
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
/// Plain on purpose — the facts, the devices, every set, one button.
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
    @State private var editing = false
    @State private var choosingMonitor = false
    @State private var ringChosen = WorkoutMonitorPreference.usesRing
    /// Outdoors: a past route to follow.
    @State private var guide: RouteGuide?
    @State private var choosingRoute = false
    /// The person picked a wearable here (not just the screen's default).
    @State private var choseMonitor = false

    init(choice: WorkoutChoice, store: TrainingStore = .shared, library: ExerciseLibrary = .shared,
         monitors: [WorkoutMonitor]? = nil, ring: RingManager = WearablesHub.shared.ring, guide: RouteGuide? = nil,
         onStart: @escaping (WorkoutChoice) -> Void) {
        self.choice = choice
        _guide = State(initialValue: guide)
        self.store = store
        self.library = library
        self.monitors = monitors
        self.onStart = onStart
        _ring = ObservedObject(wrappedValue: ring)
        _ringSession = ObservedObject(wrappedValue: ring.session)
        // Outside with no ring paired, the phone records it: nothing to choose.
        let paired = WearableIdentity.remembered(WearableKeepAlive.ring) != nil
        _ringChosen = State(initialValue: WorkoutMonitorPreference.usesRing && (paired || !choice.isOutdoor))
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
                        state: ring.state, battery: ringSession.battery, connecting: false),
            ringChosen: ringChosen,
            appleHealth: appleHealth.enabled && appleHealth.isAuthorized)
    }

    private var canStart: Bool { WorkoutMonitor.canStart(choice, ringChosen: ringChosen, ringPaired: ringPaired) }

    private var title: String {
        switch choice {
        case .sport(let sport): return sport.name
        case .strength: return template?.name ?? "Strength"
        }
    }

    /// One line of facts under the title.
    private var facts: String {
        switch choice {
        case .sport(let sport): return sport.outdoor ? "Outdoor · route, pace and elevation by GPS" : "Indoor"
        case .strength:
            guard let template else { return "Empty workout — add exercises as you go" }
            let sets = template.exercises.reduce(0) { $0 + $1.sets.filter { $0.tag != .warmup }.count }
            let minutes = TemplateEstimate.minutes(template) { store.settings(for: $0) }
            let count = template.exercises.count
            return "\(count) exercise\(count == 1 ? "" : "s") · \(sets) set\(sets == 1 ? "" : "s") · about \(minutes) min"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                tracking
                if choice.isOutdoor { routeCard }
                if let template { breakdown(template) }
            }
            .padding(.top, 4)
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
        .sheet(isPresented: $choosingMonitor) {
            MonitorPicker(choice: choice, ring: ring, ringChosen: $ringChosen)
        }
        .sheet(isPresented: $choosingRoute) { RoutePicker(guide: $guide) }
        .onChange(of: ringChosen) { _, chosen in
            choseMonitor = true
            WorkoutMonitorPreference.usesRing = chosen
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(facts)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let template, let last = store.lastPerformed(templateID: template.id) {
                Text("Last done \(last.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tracking

    /// Outdoors: follow a past route, or just record.
    private var routeCard: some View {
        CardGroup("Route", footer: guide == nil
                  ? "Follow one of your past routes: it's drawn on the map, with the distance left, and you're told if you stray."
                  : nil) {
            Row(minHeight: 64) {
                HStack(spacing: 12) {
                    if let guide {
                        RouteThumbnail(preview: guide.preview, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guide.title)
                            Text("\(DistanceUnit.current.distance(guide.total)) \(DistanceUnit.current.symbol) to follow")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44)
                        Text("Just record")
                    }
                    Spacer()
                    Button(guide == nil ? "Follow" : "Change") { choosingRoute = true }
                        .buttonStyle(.jcGlass(compact: true))
                        .accessibilityLabel(guide == nil ? "Follow a past route" : "Change the route")
                }
            }
        }
    }

    private var tracking: some View {
        let list = liveMonitors
        return CardGroup("Tracking", footer: WorkoutMonitor.notes(list)) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, monitor in
                if index > 0 { RowDivider() }
                if monitor.id == "ring" {
                    wearableRow(monitor)
                } else {
                    Row(minHeight: 50) {
                        HStack(spacing: 12) {
                            Image(systemName: monitor.symbol)
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(monitor.name)
                            Spacer(minLength: 8)
                            value(monitor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The wearable that tracks the workout, with its status beneath and the
    /// button that changes it.
    private func wearableRow(_ monitor: WorkoutMonitor) -> some View {
        Row(minHeight: 64) {
            HStack(spacing: 12) {
                if ringChosen && ringPaired {
                    WearableModelView(kind: WearableKeepAlive.ring, size: 44)
                } else {
                    Image(systemName: monitor.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.name)
                    value(monitor).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button(ringChosen ? "Change" : "Choose") { choosingMonitor = true }
                    .buttonStyle(.jcGlass(compact: true))
                    .accessibilityLabel(ringChosen ? "Change the wearable" : "Choose a wearable")
            }
        }
    }

    @ViewBuilder private func value(_ monitor: WorkoutMonitor) -> some View {
        switch monitor.status {
        case .ready(let text):
            HStack(spacing: 5) {
                if let battery = monitor.battery {
                    Image(systemName: Self.batterySymbol(battery))
                        .foregroundStyle(battery <= 20 ? JcTheme.amber : .secondary)
                }
                Text(text).monospacedDigit()
            }
            .foregroundStyle(.secondary)
        case .idle(let text):
            Text(text).foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting").foregroundStyle(.secondary)
            }
        case .problem(let text, _):
            Text(text).foregroundStyle(JcTheme.amber)
        case .off(let text):
            Text(text).foregroundStyle(.tertiary)
        }
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Breakdown

    private func breakdown(_ template: WorkoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Exercises").padding(.horizontal, 20)
            VStack(spacing: 12) {
                ForEach(template.exercises) { exercise in
                    ExercisePlanCard(exercise: exercise, store: store)
                }
            }
            if !template.note.isEmpty {
                Text(template.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Start

    private var startButton: some View {
        Button {
            // What the screen shows is what starts — saved as the preference
            // only when the person chose it (not when no ring forced it).
            if choseMonitor { WorkoutMonitorPreference.usesRing = ringChosen }
            ring.workout.nextStartUsesRing = ringChosen
            ring.workout.guide = choice.isOutdoor ? guide : nil
            onStart(choice)
        } label: {
            Text("Start")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .jcLiquidGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.45)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .accessibilityLabel(template.map { "Start \($0.name)" } ?? "Start \(title)")
    }
}

/// One exercise of a template as it will be done: its rest, a pinned note,
/// and every set — last time beside the plan — in the logger's own columns.
struct ExercisePlanCard: View {
    let exercise: LoggedExercise
    @ObservedObject var store: TrainingStore

    private var unit: TrainingUnit { TrainingUnit.current }
    private var fields: [SetField] { SetRow.fields(for: exercise.kind) }
    private var settings: ExerciseSettings { store.settings(for: exercise.exerciseID) }

    /// Last time's sets for this exercise, warm-ups and working sets apart.
    private func previous(_ index: Int) -> LoggedSet? {
        let set = exercise.sets[index]
        let warmup = set.tag == .warmup
        let position = exercise.sets[..<index].filter { ($0.tag == .warmup) == warmup }.count
        return TrainingMath.previous(exerciseID: exercise.exerciseID, index: position, warmup: warmup, in: store.logs)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let group = exercise.superset {
                Capsule()
                    .fill(SupersetTint.color(group))
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 7)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name).font(.headline)
                        if exercise.superset != nil {
                            Text("Superset").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(restText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let pinned = settings.pinnedNote {
                    Label(pinned, systemImage: "pin")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                columns
                VStack(spacing: 6) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        row(set, index: index)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        // The same inset as CardGroup, so its edges meet the Tracking card's.
        .padding(.horizontal, 20)
    }

    private var restText: String {
        let working = settings.restSeconds ?? 120
        return working == 0 ? "No rest" : "Rest \(SetRow.clock(working))"
    }

    private var columns: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: 30, alignment: .leading)
            Text("PREVIOUS").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(fields, id: \.self) { field in
                Text(SetRow.heading(field, kind: exercise.kind, unit: unit)).frame(width: 56, alignment: .trailing)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .kerning(0.4)
        .foregroundStyle(JcTheme.muted)
        .accessibilityHidden(true)
    }

    private func row(_ set: LoggedSet, index: Int) -> some View {
        let number = exercise.sets[..<index].filter { $0.tag != .warmup }.count + 1
        let last = previous(index)
        return HStack(spacing: 8) {
            Text(set.tag.badge ?? "\(number)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(badgeColor(set.tag))
                .frame(width: 30, alignment: .leading)
            Text(last.map { SetRow.describe($0, kind: exercise.kind, unit: unit) } ?? "—")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(fields, id: \.self) { field in
                Text(value(field, of: set))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(set, number: number, last: last))
    }

    private func badgeColor(_ tag: SetTag) -> Color {
        switch tag {
        case .working: return .primary
        case .warmup: return JcTheme.amber
        case .drop: return JcTheme.accentAlt
        case .failure: return JcTheme.danger
        }
    }

    private func value(_ field: SetField, of set: LoggedSet) -> String {
        switch field {
        case .weight: return set.kg.map { unit.format($0) } ?? "—"
        case .reps: return set.reps.map(String.init) ?? "—"
        case .seconds: return set.seconds.map(SetRow.clock) ?? "—"
        case .meters: return set.meters.map { TrainingUnit.number($0 / (unit == .kg ? 1000 : 1609.344)) } ?? "—"
        }
    }

    private func accessibility(_ set: LoggedSet, number: Int, last: LoggedSet?) -> String {
        let name = set.tag == .working ? "Set \(number)" : set.tag.label
        let plan = SetRow.describe(set, kind: exercise.kind, unit: unit)
        return last.map { "\(name): \(plan). Last time \(SetRow.describe($0, kind: exercise.kind, unit: unit))." } ?? "\(name): \(plan)."
    }
}

/// The bottom sheet behind Change: the wearables that can track a workout,
/// each with its state and a Connect or Reconnect, and "No wearable".
struct MonitorPicker: View {
    let choice: WorkoutChoice
    @ObservedObject var ring: RingManager
    @Binding var ringChosen: Bool
    @ObservedObject private var ringSession: RingSession
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    init(choice: WorkoutChoice, ring: RingManager, ringChosen: Binding<Bool>) {
        self.choice = choice
        self.ring = ring
        _ringChosen = ringChosen
        _ringSession = ObservedObject(wrappedValue: ring.session)
    }

    private var paired: Bool { WearableIdentity.remembered(WearableKeepAlive.ring) != nil }
    private var name: String { WearableNames.shared.name(WearableKeepAlive.ring, fallback: "Colmi R12") }
    /// Every other paired wearable, shown so the list is complete.
    @State private var others: [WearableEntry] = []
    private var busy: Bool { working || [.scanning, .connecting, .discovering].contains(ring.state) }

    /// "Connected · 82% battery", "Not connected", "Not in range".
    private var status: (text: String, warning: Bool) {
        switch ring.state {
        case .ready:
            if ringSession.battery?.charging == true { return ("On its charger", true) }
            return (ringSession.battery.map { "Connected · \($0.percent)% battery" } ?? "Connected", false)
        case .scanning, .connecting, .discovering: return ("Connecting…", false)
        case .failed: return ("Not in range", true)
        case .idle: return ("Not connected", false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    CardGroup("Tracks workouts", footer: "Pair more wearables in Devices.") {
                        if paired {
                            ringRow
                        } else {
                            Row(minHeight: 56) { Text("No ring paired").foregroundStyle(.secondary) }
                        }
                    }
                    if !others.isEmpty {
                        CardGroup("Other wearables", footer: "These don't measure heart rate, so they can't track a workout.") {
                            ForEach(Array(others.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { RowDivider() }
                                Row(minHeight: 68) {
                                    HStack(spacing: 12) {
                                        WearableModelView(kind: entry.kind, size: 48, spins: false)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name)
                                            Text(entry.connected ? "Connected" : "Not connected")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .opacity(0.6)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    CardGroup(footer: choice.isStrength || choice.isOutdoor
                              ? nil : "A \(choice.sportName.lowercased()) is recorded by the ring.") {
                        Button {
                            ringChosen = false
                            dismiss()
                        } label: {
                            Row(minHeight: 56) {
                                HStack(spacing: 12) {
                                    Image(systemName: "circle.dashed").foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("No wearable").foregroundStyle(.primary)
                                        Text(choice.isOutdoor ? "Route, pace and distance by the iPhone's GPS"
                                             : "Sets are logged without heart rate")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !ringChosen { Image(systemName: "checkmark").foregroundStyle(JcTheme.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!choice.isStrength && !choice.isOutdoor)
                        .opacity(choice.isStrength || choice.isOutdoor ? 1 : 0.45)
                        .accessibilityAddTraits(ringChosen ? .isButton : [.isButton, .isSelected])
                    }
                }
                .padding(.top, 8)
            }
            .jcScreen("Health Monitoring")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(JcTheme.bg)
        .onAppear { others = WearablesHub.shared.roster().filter { $0.kind != WearableKeepAlive.ring } }
    }

    private var ringRow: some View {
        Row(minHeight: 76) {
            HStack(spacing: 12) {
                Button {
                    ringChosen = true
                } label: {
                    HStack(spacing: 12) {
                        WearableModelView(kind: WearableKeepAlive.ring, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).foregroundStyle(.primary)
                            Text(status.text)
                                .font(.subheadline)
                                .foregroundStyle(status.warning ? JcTheme.amber : .secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        if ringChosen { Image(systemName: "checkmark").foregroundStyle(JcTheme.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(ringChosen ? [.isButton, .isSelected] : .isButton)
                connectButton
            }
        }
    }

    @ViewBuilder private var connectButton: some View {
        if busy {
            ProgressView().controlSize(.small).frame(width: 96)
        } else {
            let connected = ring.state == .ready
            Button(connected ? "Reconnect" : "Connect") {
                working = true
                Task {
                    // Reconnect starts the link afresh; Connect reopens the known ring.
                    if connected { ring.disconnect() }
                    _ = await ring.ensureConnected(timeout: 12)
                    working = false
                }
            }
            .buttonStyle(.jcGlass(compact: true))
        }
    }
}
