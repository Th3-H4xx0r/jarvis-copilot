import SwiftUI

/// A workout's or template's exercises as cards, with everything that opens
/// from them: adding exercises, replacing one, linking a superset, and an
/// exercise's detail.
struct StrengthExerciseList: View {
    @ObservedObject var session: StrengthSession
    @State private var sheet: ListSheet?
    @State private var linking: UUID?

    private enum ListSheet: Identifiable {
        case add
        case replace(UUID)
        case detail(String)

        var id: String {
            switch self {
            case .add: return "add"
            case .replace(let id): return "replace-\(id)"
            case .detail(let id): return "detail-\(id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(session.log.exercises) { exercise in
                StrengthExerciseCard(session: session, exercise: exercise,
                                     onDetail: { sheet = .detail($0) },
                                     onReplace: { sheet = .replace($0) },
                                     onSuperset: { linking = $0 })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Button { sheet = .add } label: {
                Label("Add Exercises", systemImage: "plus")
            }
            .buttonStyle(.jcGlass(full: true))
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .confirmationDialog("Superset with", isPresented: Binding(get: { linking != nil }, set: { if !$0 { linking = nil } }),
                            titleVisibility: .visible) {
            ForEach(session.log.exercises.filter { $0.id != linking }) { other in
                Button(other.name) {
                    if let linking { withAnimation(.snappy) { session.superset(linking, with: other.id) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .add:
                ExercisePicker(store: session.store, library: session.library) { ids, superset in
                    withAnimation(.snappy) { session.addExercises(ids, asSuperset: superset) }
                }
            case .replace(let exercise):
                ExercisePicker(store: session.store, library: session.library, single: true) { ids, _ in
                    if let id = ids.first { withAnimation(.snappy) { session.replace(exercise, with: id) } }
                }
            case .detail(let id):
                NavigationStack {
                    ExerciseDetailView(exerciseID: id, store: session.store, library: session.library)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
                }
            }
        }
    }
}
