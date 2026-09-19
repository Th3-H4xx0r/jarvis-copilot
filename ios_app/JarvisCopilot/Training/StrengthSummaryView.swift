import Charts
import SwiftUI

/// A strength workout, done: what was lifted, the records it set, how the
/// heart took it and how hard it was. After a workout it saves (offering to
/// update or make a template); from history it only shows.
struct StrengthSummaryView: View {
    let workout: RingWorkout
    @ObservedObject var store: TrainingStore
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    @State private var prompt: TemplatePrompt?
    @State private var naming = false
    @State private var templateName = ""
    @State private var confirmingDiscard = false

    private enum TemplatePrompt: Identifiable {
        case structure(WorkoutTemplate), values(WorkoutTemplate)
        var id: String {
            switch self {
            case .structure(let t): return "s-\(t.id)"
            case .values(let t): return "v-\(t.id)"
            }
        }
    }

    private var log: StrengthLog { workout.strength ?? .empty(at: workout.start) }
    private var unit: TrainingUnit { TrainingUnit.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StrengthSummaryContent(workout: workout)
                    .padding(.top, onSave == nil ? 8 : 40)
                if onSave != nil || onDiscard != nil { buttons }
            }
            .padding(.bottom, 28)
        }
        .confirmationDialog(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                            titleVisibility: .visible, presenting: prompt) { which in
            switch which {
            case .structure(let template):
                Button("Update Template") {
                    var updated = TrainingMath.template(from: log, id: template.id, name: template.name, order: template.order)
                    updated.note = template.note
                    store.saveTemplate(updated)
                    onSave?()
                }
                Button("Keep Original") { onSave?() }
            case .values(let template):
                Button("Update Values") {
                    store.saveTemplate(TrainingMath.updatingValues(template, from: log))
                    onSave?()
                }
                Button("Keep Original") { onSave?() }
            }
        } message: { which in
            switch which {
            case .structure: Text("You changed its exercises or sets. Update the template to match this workout?")
            case .values: Text("Save today's weights and reps into the template for next time?")
            }
        }
        .alert("Save as a template?", isPresented: $naming) {
            TextField("Name", text: $templateName)
            Button("Save Template") {
                let name = templateName.trimmingCharacters(in: .whitespaces)
                store.saveTemplate(TrainingMath.template(from: log, id: WorkoutTemplate.newID(),
                                                         name: name.isEmpty ? log.name : name, order: 0))
                onSave?()
            }
            Button("Not Now", role: .cancel) { onSave?() }
        } message: {
            Text("Start it again from the workout picker in one tap.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) { onDiscard?() }
            Button("Keep It", role: .cancel) {}
        } message: {
            Text("It won't be saved to Health.")
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .structure(let t), .values(let t): return "Update “\(t.name)”?"
        case nil: return ""
        }
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            if onDiscard != nil {
                Button("Discard") { confirmingDiscard = true }
                    .buttonStyle(.jcGlass(tint: .secondary, full: true))
            }
            if onSave != nil {
                Button("Save to Health") { save() }
                    .buttonStyle(.jcGlass(full: true))
            }
        }
        .padding(.horizontal, 20)
    }

    private func save() {
        if let id = log.templateID, let template = store.templates.first(where: { $0.id == id }) {
            switch TrainingMath.change(from: template, to: log) {
            case .structure: return prompt = .structure(template)
            case .valuesOnly: return prompt = .values(template)
            case .none: return onSave?() ?? ()
            }
        }
        if log.templateID == nil, log.exercises.contains(where: { $0.sets.contains(where: \.isDone) }) {
            templateName = log.name
            naming = true
            return
        }
        onSave?()
    }
}

/// The body of a strength summary, shared by the summary and the history detail.
struct StrengthSummaryContent: View {
    let workout: RingWorkout

    private var log: StrengthLog { workout.strength ?? .empty(at: workout.start) }
    private var unit: TrainingUnit { TrainingUnit.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label(log.name, systemImage: RingSport.withID(RingSport.strengthID).symbol)
                    .font(.headline)
                    .foregroundStyle(JcTheme.accent)
                Text(WorkoutLiveView.clock(workout.activeSeconds))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(workout.start.formatted(date: .abbreviated, time: .shortened)) – \(workout.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !log.note.isEmpty {
                    Text(log.note).font(.subheadline).padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)

            CardGroup("Summary") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 16) {
                    item("Volume", "\(Int(unit.show(log.volumeKg).rounded()).formatted()) \(unit.symbol)")
                    item("Sets", "\(log.sets)")
                    item("Reps", "\(log.reps)")
                    item("Avg heart rate", workout.heartRateAverage.map { "\($0) bpm" })
                    item("Max heart rate", workout.heartRateMax.map { "\($0) bpm" })
                    item("Calories", "\(Int(workout.kilocalories.rounded())) kcal", note: calorieNote)
                    item("Lifting", Self.duration(log.activeSeconds))
                    item("Resting", Self.duration(log.restSeconds))
                }
                .padding(16)
                if let effort = workout.effort {
                    RowDivider()
                    EffortBar(effort: effort).padding(16)
                }
            }

            let records = recordLines
            if !records.isEmpty {
                CardGroup("Personal records") {
                    ForEach(Array(records.enumerated()), id: \.offset) { i, line in
                        if i > 0 { RowDivider() }
                        Row(minHeight: 46) {
                            HStack(spacing: 12) {
                                Image(systemName: "trophy.fill").foregroundStyle(JcTheme.amber)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(line.0).font(.subheadline.weight(.semibold))
                                    Text(line.1).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if workout.heartRates.contains(where: { $0 > 0 }) {
                CardGroup("Heart rate", footer: "Shaded: your sets. Between them, how fast your heart settled.") {
                    StrengthTrace(workout: workout).frame(height: 160).padding(14)
                }
            }

            CardGroup("Exercises") {
                ForEach(Array(log.exercises.enumerated()), id: \.element.id) { i, exercise in
                    if i > 0 { RowDivider() }
                    exerciseBlock(exercise)
                }
            }
        }
    }

    private var calorieNote: String? {
        switch workout.kcalSource {
        case "heart_rate": return "from heart rate"
        case "ring": return "from the ring"
        case "estimate": return "estimated"
        default: return nil
        }
    }

    /// "1h 05m", "18 min", "40 s".
    static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60) }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    private func item(_ label: String, _ value: String?, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    /// "Bench Press" / "Estimated 1RM 78.8 kg · 72.5 kg × 5".
    private var recordLines: [(String, String)] {
        var out: [(String, String)] = []
        for exercise in log.exercises {
            for set in exercise.sets where !set.records.isEmpty {
                let what = set.records.map { name -> String in
                    switch name {
                    case "e1rm": return set.e1rm.map { "Estimated 1RM \(unit.estimate($0)) \(unit.symbol)" } ?? "Estimated 1RM"
                    case "weight": return "Heaviest weight"
                    case "volume": return "Best set volume"
                    case "reps": return "Most reps"
                    default: return "Longest set"
                    }
                }
                out.append((exercise.name, (what + [SetRow.describe(set, kind: exercise.kind, unit: unit)]).joined(separator: " · ")))
            }
        }
        return out
    }

    private func exerciseBlock(_ exercise: LoggedExercise) -> some View {
        let done = exercise.sets.filter(\.isDone)
        let best = done.filter { $0.tag != .warmup }.max { ($0.e1rm ?? Double($0.reps ?? 0)) < ($1.e1rm ?? Double($1.reps ?? 0)) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(exercise.name).font(.subheadline.weight(.semibold))
            if done.isEmpty {
                Text("Not done").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(done.enumerated()), id: \.element.id) { i, set in
                HStack(spacing: 8) {
                    Text(set.tag.badge ?? "\(done[..<i].filter { $0.tag != .warmup }.count + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(set.tag == .warmup ? JcTheme.amber : JcTheme.muted)
                        .frame(width: 18, alignment: .leading)
                    Text(SetRow.describe(set, kind: exercise.kind, unit: unit) + (set.rpe.map { " @\(TrainingUnit.number($0))" } ?? ""))
                        .font(.system(.subheadline, design: .rounded).weight(set.id == best?.id ? .bold : .regular))
                        .monospacedDigit()
                    if !set.records.isEmpty { Image(systemName: "trophy.fill").font(.caption2).foregroundStyle(JcTheme.amber) }
                    Spacer()
                    if let hr = set.hrAvg {
                        Label("\(hr)", systemImage: "heart.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RingMeasurementType.heartRate.tint.opacity(0.9))
                            .monospacedDigit()
                    }
                    if let drop = set.hrDrop {
                        Text("↓\(drop)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(16)
    }
}

/// Effort 1–10 as ten segments, coloured by how hard.
struct EffortBar: View {
    let effort: Int

    static func band(_ effort: Int) -> (String, Color) {
        switch effort {
        case ...3: return ("Easy", JcTheme.success)
        case 4...6: return ("Moderate", JcTheme.accent)
        case 7...8: return ("Hard", JcTheme.amber)
        default: return ("All out", JcTheme.danger)
        }
    }

    var body: some View {
        let band = Self.band(effort)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Effort").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(effort)").font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(band.1)
                Text("/ 10 · \(band.0)").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { i in
                    Capsule().fill(i <= effort ? band.1 : Color.white.opacity(0.1)).frame(height: 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort \(effort) out of 10, \(band.0)")
    }
}

/// Heart rate across a strength workout with each set shaded.
struct StrengthTrace: View {
    let workout: RingWorkout

    private struct Point: Identifiable { let id: Int; let minute: Double; let bpm: Double }
    private struct Band: Identifiable { let id: UUID; let from: Double; let to: Double }

    var body: some View {
        let points = workout.heartRates.enumerated().compactMap { i, bpm in
            bpm > 0 ? Point(id: i, minute: Double(i * 5) / 60, bpm: Double(bpm)) : nil
        }
        let bands: [Band] = (workout.strength?.exercises ?? []).flatMap(\.sets).compactMap { set in
            guard let done = set.done, let start = set.start else { return nil }
            return Band(id: set.id, from: start.timeIntervalSince(workout.start) / 60, to: done.timeIntervalSince(workout.start) / 60)
        }
        let floor = max(40, (points.map(\.bpm).min() ?? 60) - 10)
        let ceiling = (points.map(\.bpm).max() ?? 160) + 8
        let tint = RingMeasurementType.heartRate.tint
        return Chart {
            ForEach(bands) { band in
                RectangleMark(xStart: .value("From", band.from), xEnd: .value("To", max(band.to, band.from + 0.15)),
                              yStart: .value("Floor", floor), yEnd: .value("Ceiling", ceiling))
                    .foregroundStyle(JcTheme.accent.opacity(0.16))
            }
            ForEach(points) { point in
                LineMark(x: .value("Minute", point.minute), y: .value("bpm", point.bpm))
                    .foregroundStyle(tint)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: floor...ceiling)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0))m") }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
