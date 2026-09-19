import SwiftUI

/// Changing a saved workout everywhere it lives: the phone's history, Jarvis
/// Health and Apple Health.
@MainActor
enum WorkoutEditing {
    static var deviceID: String? { WearablesHub.shared.ring.deviceID }

    static func delete(_ workout: RingWorkout, store: TrainingStore = .shared, announce: Bool = true) {
        WorkoutUploader.forget(start: workout.start)
        store.removeWorkout(start: workout.start, device: workout.device, deviceID: deviceID)
        // The server drops its copy of the route with the workout.
        RouteStore.shared.delete(start: workout.start)
        Task {
            await AppleHealthWriter.shared.remove(start: workout.start)
            await store.flush()
            if announce { NotificationCenter.default.post(name: .jcWorkoutsSynced, object: nil) }
        }
    }

    /// An edited workout in place of the old one (moved, if its start changed).
    static func replace(_ old: RingWorkout, with new: RingWorkout, store: TrainingStore = .shared) {
        if abs(old.start.timeIntervalSince(new.start)) >= 1 { delete(old, store: store, announce: false) }
        store.record(new)
        Task {
            await WorkoutUploader.save(new, deviceID: deviceID)
            await AppleHealthWriter.shared.export(new)
        }
    }
}

/// A saved strength workout, from the Health tab: everything the summary
/// showed, and Edit, Save as Template and Delete.
struct StrengthWorkoutDetail: View {
    @State var workout: RingWorkout
    @ObservedObject var store: TrainingStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var naming = false
    @State private var templateName = ""
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            StrengthSummaryContent(workout: workout)
                .padding(.top, 8)
                .padding(.bottom, 28)
        }
        .background(JcTheme.bg)
        .navigationTitle(workout.strength?.name ?? workout.sportName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("Edit Workout", systemImage: "pencil") }
                    Button {
                        templateName = workout.strength?.name ?? ""
                        naming = true
                    } label: { Label("Save as Template", systemImage: "list.bullet.clipboard") }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Workout", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Workout options")
            }
        }
        .sheet(isPresented: $editing) {
            StrengthEditView(workout: workout, store: store) { edited in
                WorkoutEditing.replace(workout, with: edited, store: store)
                workout = edited
            }
        }
        .alert("Save as a template", isPresented: $naming) {
            TextField("Name", text: $templateName)
            Button("Save") {
                guard let log = workout.strength else { return }
                let name = templateName.trimmingCharacters(in: .whitespaces)
                store.saveTemplate(TrainingMath.template(from: log, id: WorkoutTemplate.newID(),
                                                         name: name.isEmpty ? log.name : name, order: 0))
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                WorkoutEditing.delete(workout, store: store)
                dismiss()
            }
        } message: {
            Text("It goes from Jarvis Health and Apple Health, and from your exercise history.")
        }
    }
}

/// Correct a finished workout: its times, exercises, sets and notes.
struct StrengthEditView: View {
    let original: RingWorkout
    let onSave: (RingWorkout) -> Void
    @ObservedObject private var store: TrainingStore
    @StateObject private var session: StrengthSession
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(workout: RingWorkout, store: TrainingStore = .shared, library: ExerciseLibrary = .shared,
         onSave: @escaping (RingWorkout) -> Void) {
        original = workout
        self.onSave = onSave
        self.store = store
        _start = State(initialValue: workout.start)
        _end = State(initialValue: workout.end)
        _session = StateObject(wrappedValue: StrengthSession(log: workout.strength ?? .empty(at: workout.start),
                                                             mode: .editing, store: store, library: library))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Workout name", text: $session.log.name)
                                .font(.title2.weight(.bold))
                            DatePicker("Started", selection: Binding(get: { start }, set: { value in
                                // Moving the start moves the whole workout, end included.
                                end = end.addingTimeInterval(value.timeIntervalSince(start))
                                start = value
                            }))
                            DatePicker("Finished", selection: $end, in: start...)
                            TextField("Add a note", text: $session.log.note, axis: .vertical)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .tint(JcTheme.accent)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        StrengthExerciseList(session: session)
                    }
                    .padding(.bottom, 32)
                }
                .onChange(of: session.focus) { _, focus in
                    if let focus { withAnimation { proxy.scrollTo(focus.set, anchor: .center) } }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SetKeypad(session: session) }
            .animation(.snappy, value: session.focus != nil)
            .jcScreen("Edit Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(edited())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// The workout with the edits: totals and estimated maxes worked out
    /// again; heart rate stays what the ring measured.
    private func edited() -> RingWorkout {
        var log = session.log
        let shift = start.timeIntervalSince(original.start)
        if abs(shift) >= 1 {
            log.exercises = log.exercises.map { e in
                var e = e
                e.sets = e.sets.map { s in
                    var s = s
                    s.done = s.done?.addingTimeInterval(shift)
                    s.start = s.start?.addingTimeInterval(shift)
                    s.restEnd = s.restEnd?.addingTimeInterval(shift)
                    return s
                }
                return e
            }
        }
        log.started = start.wholeSeconds
        log = SessionVitals.annotate(log, samples: [], end: end)
        let others = store.logs.filter { abs($0.started.timeIntervalSince(original.start)) >= 1 && $0.started < log.started }
        let marks = TrainingMath.newRecords(in: log, history: others)
        for e in log.exercises.indices {
            for s in log.exercises[e].sets.indices {
                log.exercises[e].sets[s].records = marks[log.exercises[e].sets[s].id] ?? []
            }
        }
        var out = original
        out.start = start.wholeSeconds
        out.end = max(end, start)
        out.activeSeconds = Int(out.end.timeIntervalSince(out.start))
        out.sportName = log.name
        out.strength = log
        return out
    }
}
