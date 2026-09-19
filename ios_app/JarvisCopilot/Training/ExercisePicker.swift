import SwiftUI

/// Choose exercises: search, filter by muscle or equipment, recent ones
/// first, several at once (as a superset if wanted), or make a new one.
struct ExercisePicker: View {
    @ObservedObject var store: TrainingStore
    let library: ExerciseLibrary
    /// Replacing: one exercise, chosen with a tap.
    var single = false
    let onAdd: ([String], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var muscle: String?
    @State private var equipment: Equipment?
    @State private var selected: [String] = []
    @State private var creating = false
    @State private var info: String?

    private var all: [Exercise] { library.all(custom: store.customExercises, settings: store.settings) }

    private var filtered: [Exercise] { ExerciseLibrary.search(all, text: text, muscle: muscle, equipment: equipment) }

    private var recent: [Exercise] {
        guard text.isEmpty, muscle == nil, equipment == nil else { return [] }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return store.recentExerciseIDs(limit: 8).compactMap { byID[$0] }
    }

    /// A–Z sections, or one ranked list while searching.
    private var sections: [(String, [Exercise])] {
        let list = filtered
        guard text.isEmpty else { return [("Results", list)] }
        let grouped = Dictionary(grouping: list) { exercise -> String in
            let first = exercise.name.prefix(1).uppercased()
            return first.rangeOfCharacter(from: .letters) == nil ? "#" : first
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !recent.isEmpty {
                    Section("Recent") { ForEach(recent) { row($0) } }
                }
                ForEach(sections, id: \.0) { title, exercises in
                    Section(title) { ForEach(exercises) { row($0) } }
                }
                if filtered.isEmpty {
                    Section {
                        Button { creating = true } label: {
                            Label(text.isEmpty ? "Create an exercise" : "Create “\(text)”", systemImage: "plus.circle")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .jcScreen(single ? "Replace Exercise" : "Add Exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New") { creating = true } }
            }
            .safeAreaInset(edge: .top, spacing: 0) { filters.padding(.horizontal, 16).background(JcTheme.bg) }
            .safeAreaInset(edge: .bottom) { if !single && !selected.isEmpty { addBar } }
            .sheet(isPresented: $creating) {
                CustomExerciseForm(store: store, name: text) { exercise in
                    if single { finish([exercise.id], superset: false) } else { selected.append(exercise.id) }
                }
            }
            .sheet(item: Binding(get: { info.map(InfoID.init) }, set: { info = $0?.id })) { item in
                NavigationStack {
                    ExerciseDetailView(exerciseID: item.id, store: store, library: library)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { info = nil } } }
                }
            }
        }
        .presentationBackground(JcTheme.bg)
    }

    private struct InfoID: Identifiable { let id: String }

    private var filters: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Any muscle") { muscle = nil }
                ForEach(ExerciseLibrary.muscles, id: \.self) { m in Button(m.capitalized) { muscle = m } }
            } label: { chip(muscle?.capitalized ?? "Muscle", active: muscle != nil) }
            Menu {
                Button("Any equipment") { equipment = nil }
                ForEach(Equipment.allCases) { e in Button(e.label) { equipment = e } }
            } label: { chip(equipment?.label ?? "Equipment", active: equipment != nil) }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func chip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(active ? Color.black : JcTheme.text)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(active ? JcTheme.accent : Color.white.opacity(0.1), in: Capsule())
    }

    private func row(_ exercise: Exercise) -> some View {
        let chosen = selected.contains(exercise.id)
        return HStack(spacing: 12) {
            ExerciseThumbnail(exercise: exercise)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(.body.weight(.medium)).lineLimit(2)
                Text(exercise.custom ? "\(exercise.subtitle) · Custom" : exercise.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if chosen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(JcTheme.accent)
            } else {
                Button { info = exercise.id } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("About \(exercise.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if single { return finish([exercise.id], superset: false) }
            withAnimation(.snappy(duration: 0.18)) {
                if chosen { selected.removeAll { $0 == exercise.id } } else { selected.append(exercise.id) }
            }
        }
        .listRowBackground(chosen ? JcTheme.accent.opacity(0.12) : Color.clear)
        .listRowSeparatorTint(Color.white.opacity(0.08))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private var addBar: some View {
        HStack(spacing: 12) {
            if selected.count > 1 {
                Button { finish(selected, superset: true) } label: { Label("Superset", systemImage: "link") }
                    .buttonStyle(.jcGlass(tint: JcTheme.amber, full: true))
            }
            Button { finish(selected, superset: false) } label: {
                Text(selected.count == 1 ? "Add 1 Exercise" : "Add \(selected.count) Exercises")
            }
            .buttonStyle(.jcGlass(full: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func finish(_ ids: [String], superset: Bool) {
        onAdd(ids, superset)
        dismiss()
    }
}

/// A new exercise of the person's own.
struct CustomExerciseForm: View {
    @ObservedObject var store: TrainingStore
    let onCreated: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var equipment: Equipment = .barbell
    @State private var kind: ExerciseKind = .weightReps
    @State private var muscle = "chest"

    init(store: TrainingStore, name: String = "", onCreated: @escaping (Exercise) -> Void) {
        self.store = store
        self.onCreated = onCreated
        _name = State(initialValue: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section {
                    Picker("Equipment", selection: $equipment) {
                        ForEach(Equipment.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Records", selection: $kind) {
                        ForEach(ExerciseKind.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Main muscle", selection: $muscle) {
                        ForEach(ExerciseLibrary.muscles, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                } footer: {
                    Text("“Records” decides the columns: weight and reps, reps alone, time, or distance and time.")
                }
            }
            .scrollContentBackground(.hidden)
            .jcScreen("New Exercise")
            .onChange(of: equipment) { _, value in
                kind = ExerciseLibrary.kind(category: "strength", equipment: value)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let exercise = Exercise(id: "custom-" + UUID().uuidString.lowercased(),
                                                name: name.trimmingCharacters(in: .whitespaces), equipment: equipment,
                                                kind: kind, primaryMuscles: [muscle], custom: true)
                        store.saveExercise(exercise)
                        onCreated(exercise)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationBackground(JcTheme.bg)
    }
}
