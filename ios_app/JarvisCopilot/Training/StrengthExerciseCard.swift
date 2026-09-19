import SwiftUI

/// Superset groups told apart by colour, from the theme's tokens.
enum SupersetTint {
    static func color(_ group: Int) -> Color {
        let palette = [JcTheme.accent, JcTheme.amber, JcTheme.accentAlt, JcTheme.success, JcTheme.blue]
        return palette[(max(1, group) - 1) % palette.count]
    }
}

/// One exercise and its sets, as Strong lays them out: Set · Previous ·
/// weight · reps · ✓. The same card plans a template (no ✓), logs a live
/// workout and corrects a finished one.
struct StrengthExerciseCard: View {
    @ObservedObject var session: StrengthSession
    let exercise: LoggedExercise
    var onDetail: (String) -> Void = { _ in }
    var onReplace: (UUID) -> Void = { _ in }
    var onSuperset: (UUID) -> Void = { _ in }
    @State private var editingNote = false
    @State private var pinning = false
    @State private var pinText = ""
    @State private var restPicker = false

    private var unit: TrainingUnit { session.unit }
    private var ticks: Bool { session.mode != .template }
    private var pinned: String? { session.store.settings(for: exercise.exerciseID).pinnedNote }

    var body: some View {
        HStack(spacing: 0) {
            if let group = exercise.superset {
                Capsule()
                    .fill(SupersetTint.color(group))
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 6)
                    .accessibilityLabel("Superset")
            }
            VStack(alignment: .leading, spacing: 10) {
                header
                if let pinned {
                    Label(pinned, systemImage: "pin.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(JcTheme.amber)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(JcTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if editingNote || !exercise.note.isEmpty {
                    TextField("Exercise note", text: Binding(get: { exercise.note },
                                                              set: { session.setNote($0, for: exercise.id) }),
                              axis: .vertical)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                columns
                VStack(spacing: 2) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(session: session, exercise: exercise, set: set, number: number(at: index))
                            .id(set.id)
                            .swipeToDelete { withAnimation(.snappy) { session.removeSet(set.id, in: exercise.id) } }
                    }
                }
                Button {
                    withAnimation(.snappy) { session.addSet(exercise.id) }
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            .padding(14)
        }
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .alert("Pinned note", isPresented: $pinning) {
            TextField("Shown every time you do this", text: $pinText)
            Button("Save") { session.setPinnedNote(pinText, for: exercise.exerciseID) }
            if pinned != nil { Button("Remove", role: .destructive) { session.setPinnedNote(nil, for: exercise.exerciseID) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $restPicker) {
            RestSettingsSheet(session: session, exercise: exercise)
                .presentationDetents([.height(320)])
        }
    }

    /// Working sets are numbered; warm-ups show W.
    private func number(at index: Int) -> Int {
        exercise.sets[..<index].filter { $0.tag != .warmup }.count + 1
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { onDetail(exercise.exerciseID) } label: {
                Text(exercise.name)
                    .font(.headline)
                    .foregroundStyle(JcTheme.accent)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Menu {
                Button { editingNote = true } label: { Label("Add Note", systemImage: "note.text") }
                Button { pinText = pinned ?? ""; pinning = true } label: { Label("Pinned Note", systemImage: "pin") }
                Button { restPicker = true } label: { Label("Rest Timers", systemImage: "timer") }
                if exercise.kind.usesWeight {
                    Button { withAnimation(.snappy) { session.addWarmups(exercise.id) } } label: {
                        Label("Add Warm-up Sets", systemImage: "flame")
                    }
                }
                Divider()
                Button { onReplace(exercise.id) } label: { Label("Replace Exercise", systemImage: "arrow.left.arrow.right") }
                if exercise.superset == nil {
                    Button { onSuperset(exercise.id) } label: { Label("Superset With…", systemImage: "link") }
                } else {
                    Button { withAnimation(.snappy) { session.unlink(exercise.id) } } label: {
                        Label("Remove from Superset", systemImage: "link.badge.plus")
                    }
                }
                Button(role: .destructive) { withAnimation(.snappy) { session.remove(exercise.id) } } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 34, height: 28)
                    .background(JcTheme.accent.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("\(exercise.name) options")
        }
    }

    private var columns: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: SetRow.badgeWidth)
            Text("PREVIOUS").frame(maxWidth: .infinity)
            ForEach(SetRow.fields(for: exercise.kind), id: \.self) { field in
                Text(SetRow.heading(field, kind: exercise.kind, unit: unit)).frame(width: SetRow.cellWidth)
            }
            if ticks { Image(systemName: "checkmark").frame(width: SetRow.checkWidth) }
        }
        .font(.system(size: 11, weight: .bold))
        .kerning(0.5)
        .foregroundStyle(JcTheme.muted)
        .accessibilityHidden(true)
    }
}

/// One set's row.
struct SetRow: View {
    @ObservedObject var session: StrengthSession
    let exercise: LoggedExercise
    let set: LoggedSet
    let number: Int

    static let badgeWidth: CGFloat = 34
    static let cellWidth: CGFloat = 62
    static let checkWidth: CGFloat = 36

    static func fields(for kind: ExerciseKind) -> [SetField] {
        switch kind {
        case .weightReps, .weightedBodyweight, .assistedBodyweight: return [.weight, .reps]
        case .repsOnly: return [.reps]
        case .duration: return [.seconds]
        case .distanceDuration: return [.meters, .seconds]
        }
    }

    static func heading(_ field: SetField, kind: ExerciseKind, unit: TrainingUnit) -> String {
        switch field {
        case .weight: return kind.weightHeading(unit).uppercased()
        case .reps: return "REPS"
        case .seconds: return "TIME"
        case .meters: return unit == .kg ? "KM" : "MI"
        }
    }

    private var ticks: Bool { session.mode != .template }
    private var previous: LoggedSet? { session.previous(set.id, in: exercise.id) }

    var body: some View {
        HStack(spacing: 8) {
            badge
            Button { session.copyPrevious(set.id, in: exercise.id) } label: {
                Text(previous.map { Self.describe($0, kind: exercise.kind, unit: session.unit) } ?? "—")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(previous == nil)
            .accessibilityLabel(previous == nil ? "No previous set" : "Use previous")
            ForEach(Self.fields(for: exercise.kind), id: \.self) { field in cell(field) }
            if ticks { check }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(set.isDone && ticks ? JcTheme.success.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.snappy(duration: 0.2), value: set.isDone)
    }

    private var badge: some View {
        Menu {
            ForEach([SetTag.warmup, .drop, .failure], id: \.self) { tag in
                Button { session.setTag(tag, set: set.id, in: exercise.id) } label: {
                    if set.tag == tag { Label(tag.label, systemImage: "checkmark") } else { Text(tag.label) }
                }
            }
            if exercise.kind.usesReps {
                Menu("RPE") {
                    ForEach(Array(stride(from: 6.0, through: 10.0, by: 0.5)), id: \.self) { value in
                        Button(TrainingUnit.number(value)) { session.setRPE(value, set: set.id, in: exercise.id) }
                    }
                    if set.rpe != nil { Button("Clear RPE", role: .destructive) { session.setRPE(nil, set: set.id, in: exercise.id) } }
                }
            }
            Divider()
            Button(role: .destructive) { session.removeSet(set.id, in: exercise.id) } label: { Label("Delete Set", systemImage: "trash") }
        } label: {
            Text(set.tag.badge ?? "\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(tagColor)
                .frame(width: Self.badgeWidth, height: 30)
                .background(tagColor.opacity(set.tag == .working ? 0.0 : 0.16), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(set.tag == .working ? "Set \(number)" : set.tag.label)
    }

    private var tagColor: Color {
        switch set.tag {
        case .working: return .primary
        case .warmup: return JcTheme.amber
        case .drop: return JcTheme.accentAlt
        case .failure: return JcTheme.danger
        }
    }

    private func cell(_ field: SetField) -> some View {
        let focused = session.focus == SetFocus(exercise: exercise.id, set: set.id, field: field)
        let value = session.value(field, of: set)
        let hint = previous.flatMap { session.value(field, of: $0) }
        return Button {
            session.focus = SetFocus(exercise: exercise.id, set: set.id, field: field)
        } label: {
            HStack(spacing: 2) {
                Text(value.map { Self.format($0, field) } ?? hint.map { Self.format($0, field) } ?? "")
                    .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if field == .reps, let rpe = set.rpe {
                    Text("@\(TrainingUnit.number(rpe))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.cellWidth, height: 32)
            .background(focused ? JcTheme.accent.opacity(0.18) : Color.white.opacity(set.isDone ? 0.0 : 0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? JcTheme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.heading(field, kind: exercise.kind, unit: session.unit).lowercased())
        .accessibilityValue(value.map { Self.format($0, field) } ?? "empty")
    }

    private var check: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { session.toggleDone(set.id, in: exercise.id) }
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(set.isDone ? Color.black : JcTheme.muted)
                .frame(width: Self.checkWidth - 4, height: 30)
                .background(set.isDone ? JcTheme.success : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(width: Self.checkWidth)
        .sensoryFeedback(.success, trigger: set.isDone) { _, done in done }
        .accessibilityLabel(set.isDone ? "Done" : "Mark done")
    }

    static func format(_ value: Double, _ field: SetField) -> String {
        switch field {
        case .seconds: return clock(Int(value))
        case .reps: return String(Int(value))
        default: return TrainingUnit.number(value)
        }
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// "60 kg × 8", "12 reps", "1:30", "2.1 km · 12:00".
    static func describe(_ set: LoggedSet, kind: ExerciseKind, unit: TrainingUnit) -> String {
        switch kind {
        case .weightReps, .weightedBodyweight, .assistedBodyweight:
            let sign = kind == .weightedBodyweight ? "+" : kind == .assistedBodyweight ? "−" : ""
            let weight = set.kg.map { "\(sign)\(unit.format($0)) \(unit.symbol)" }
            let reps = set.reps.map(String.init)
            return [weight, reps].compactMap { $0 }.joined(separator: " × ")
        case .repsOnly: return set.reps.map { "\($0) reps" } ?? "—"
        case .duration: return set.seconds.map(clock) ?? "—"
        case .distanceDuration:
            let distance = set.meters.map { TrainingUnit.number($0 / (unit == .kg ? 1000 : 1609.344)) + (unit == .kg ? " km" : " mi") }
            return [distance, set.seconds.map(clock)].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// An exercise's rest timers: after working sets and after warm-ups.
struct RestSettingsSheet: View {
    @ObservedObject var session: StrengthSession
    let exercise: LoggedExercise
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                stepper("After working sets", value: session.restSeconds(for: exercise, warmup: false)) { seconds in
                    session.store.updateSettings(exercise.exerciseID) { $0.restSeconds = seconds }
                }
                stepper("After warm-ups", value: session.restSeconds(for: exercise, warmup: true)) { seconds in
                    session.store.updateSettings(exercise.exerciseID) { $0.warmupRestSeconds = seconds }
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Rest Timers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(JcTheme.surface)
    }

    private func stepper(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value == 0 ? "Off" : SetRow.clock(value))
                .monospacedDigit()
                .foregroundStyle(JcTheme.accent)
                .frame(minWidth: 48, alignment: .trailing)
            Stepper(title, value: Binding(get: { value }, set: { set($0); session.objectWillChange.send() }),
                    in: 0...600, step: 15)
                .labelsHidden()
        }
        .padding(14)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
