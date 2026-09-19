import SwiftUI

/// The picker's Templates row: a card per template to start it, a
/// long-press to edit it, and New at the end.
struct TemplatesRow: View {
    @ObservedObject var store: TrainingStore
    let onStart: (WorkoutTemplate) -> Void
    let onEdit: (WorkoutTemplate) -> Void
    let onNew: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Templates") {
                if !store.templates.isEmpty {
                    Button("Edit", action: onManage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if store.templates.isEmpty {
                        emptyCard
                    } else {
                        ForEach(store.templates) { template in card(template) }
                        newCard
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private func card(_ template: WorkoutTemplate) -> some View {
        Button { onStart(template) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(template.exercises.map(\.name).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(lastDone(template))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 168, height: 116, alignment: .topLeading)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onStart(template) } label: { Label("Start Workout", systemImage: "play.fill") }
            Button { onEdit(template) } label: { Label("Edit", systemImage: "pencil") }
            Button { store.duplicateTemplate(id: template.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { withAnimation { store.deleteTemplate(id: template.id) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel("Start \(template.name)")
        .accessibilityHint("Touch and hold to edit")
    }

    private func lastDone(_ template: WorkoutTemplate) -> String {
        guard let date = store.lastPerformed(templateID: template.id) else { return "Not done yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last done " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private var newCard: some View {
        Button(action: onNew) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("New").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(JcTheme.accent)
            .frame(width: 96, height: 116)
            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .strokeBorder(JcTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New template")
    }

    private var emptyCard: some View {
        Button(action: onNew) {
            HStack(spacing: 14) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create a template").font(.headline).foregroundStyle(.primary)
                    Text("Plan the lifts you repeat, then start them in a tap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(JcTheme.accent)
            }
            .padding(16)
            .frame(width: UIScreen.main.bounds.width - 32, alignment: .leading)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Every template, to reorder, delete or open.
struct TemplatesManager: View {
    @ObservedObject var store: TrainingStore
    let library: ExerciseLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WorkoutTemplate?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.templates) { template in
                    Button { editing = template } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(template.exercises.map(\.name).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(JcTheme.glassFill)
                }
                .onMove { store.moveTemplates(from: $0, to: $1) }
                .onDelete { offsets in
                    for id in offsets.map({ store.templates[$0].id }) { store.deleteTemplate(id: id) }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .jcScreen("Templates")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { TemplateEditor(template: $0, store: store, library: library) }
        }
    }
}
