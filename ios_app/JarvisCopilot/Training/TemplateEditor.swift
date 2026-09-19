import SwiftUI

/// Plan a template: its name, exercises and target sets.
struct TemplateEditor: View {
    private let base: WorkoutTemplate
    private let isNew: Bool
    @ObservedObject private var store: TrainingStore
    @StateObject private var session: StrengthSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    init(template: WorkoutTemplate?, store: TrainingStore = .shared, library: ExerciseLibrary = .shared) {
        let base = template ?? WorkoutTemplate(name: "", exercises: [])
        self.base = base
        isNew = template == nil
        self.store = store
        _session = StateObject(wrappedValue: StrengthSession(log: StrengthSession.log(editing: base), mode: .template,
                                                             store: store, library: library))
    }

    private var canSave: Bool {
        !session.log.name.trimmingCharacters(in: .whitespaces).isEmpty && !session.log.exercises.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Template name", text: $session.log.name)
                                .font(.title2.weight(.bold))
                                .submitLabel(.done)
                            TextField("Add a note", text: $session.log.note, axis: .vertical)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        StrengthExerciseList(session: session)
                        if !isNew {
                            Button("Delete Template", role: .destructive) { confirmingDelete = true }
                                .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.focus) { _, focus in
                    if let focus { withAnimation { proxy.scrollTo(focus.set, anchor: .center) } }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SetKeypad(session: session) }
            .animation(.snappy, value: session.focus != nil)
            .jcScreen(isNew ? "New Template" : "Edit Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveTemplate(session.template(from: base))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(base.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Template", role: .destructive) {
                    store.deleteTemplate(id: base.id)
                    dismiss()
                }
            } message: {
                Text("Workouts you did from it stay in your history.")
            }
        }
    }
}
