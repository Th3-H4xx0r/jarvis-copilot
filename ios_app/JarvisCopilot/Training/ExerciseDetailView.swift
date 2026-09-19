import Charts
import SwiftUI

/// One exercise: how to do it, every time it was done, its progress and its
/// records — and the settings that follow it everywhere.
struct ExerciseDetailView: View {
    let exerciseID: String
    @ObservedObject var store: TrainingStore
    let library: ExerciseLibrary
    @State private var tab: Tab
    @State private var metric: TrainingMath.ChartMetric?
    @State private var range: ChartRange = .year

    enum Tab: String, CaseIterable, Identifiable {
        case about = "About", history = "History", charts = "Charts", records = "Records"
        var id: String { rawValue }
    }

    enum ChartRange: String, CaseIterable, Identifiable {
        case threeMonths = "3M", year = "1Y", all = "All"
        var id: String { rawValue }
        var start: Date? {
            switch self {
            case .threeMonths: return Calendar.current.date(byAdding: .month, value: -3, to: Date())
            case .year: return Calendar.current.date(byAdding: .year, value: -1, to: Date())
            case .all: return nil
            }
        }
    }

    init(exerciseID: String, store: TrainingStore, library: ExerciseLibrary, tab: Tab = .about) {
        self.exerciseID = exerciseID
        self.store = store
        self.library = library
        _tab = State(initialValue: tab)
    }

    private var exercise: Exercise? { library.exercise(exerciseID, custom: store.customExercises, settings: store.settings) }
    private var unit: TrainingUnit { TrainingUnit.current }
    private var logs: [StrengthLog] { store.logs.filter { $0.exercises.contains { $0.exerciseID == exerciseID } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                switch tab {
                case .about: about
                case .history: history
                case .charts: charts
                case .records: records
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .jcScreen(exercise?.name ?? "Exercise")
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        if let exercise {
            if !exercise.images.isEmpty {
                TabView {
                    ForEach(exercise.images, id: \.self) { path in ExercisePhoto(path: path) }
                }
                .tabViewStyle(.page)
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
                .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 10) {
                FlowChips(items: exercise.primaryMuscles.map { ($0.capitalized, true) } + exercise.secondaryMuscles.map { ($0.capitalized, false) })
                Text([exercise.equipment.label, exercise.level?.capitalized, exercise.mechanic?.capitalized]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            if !exercise.instructions.isEmpty {
                CardGroup("How to") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(JcTheme.accent)
                                    .frame(width: 18)
                                Text(step).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            settingsCard(exercise)
            if exercise.custom {
                Button("Delete Exercise", role: .destructive) { store.deleteExercise(id: exercise.id) }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                    .padding(.horizontal, 16)
            }
        } else {
            CardEmptyBlock("This exercise is no longer in the library.", symbol: "questionmark.circle")
        }
    }

    private func settingsCard(_ exercise: Exercise) -> some View {
        let settings = store.settings(for: exercise.id)
        return CardGroup("Settings") {
            Row {
                HStack {
                    Text("Records")
                    Spacer()
                    Picker("Records", selection: Binding(get: { settings.kind ?? exercise.kind },
                                                         set: { value in store.updateSettings(exercise.id) { $0.kind = value } })) {
                        ForEach(ExerciseKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .tint(JcTheme.accent)
                }
            }
            if exercise.equipment == .barbell || exercise.equipment == .ezBar || settings.barKg != nil {
                RowDivider()
                Row {
                    HStack {
                        Text("Bar")
                        Spacer()
                        Picker("Bar", selection: Binding(get: { settings.barKg ?? exercise.equipment.defaultBarKg ?? 0 },
                                                         set: { value in store.updateSettings(exercise.id) { $0.barKg = value } })) {
                            ForEach(Self.bars(unit), id: \.self) { kg in
                                Text(kg == 0 ? "None" : "\(unit.format(kg)) \(unit.symbol)").tag(kg)
                            }
                        }
                        .labelsHidden()
                        .tint(JcTheme.accent)
                    }
                }
            }
            RowDivider()
            Row {
                Stepper(value: Binding(get: { settings.restSeconds ?? 120 },
                                       set: { value in store.updateSettings(exercise.id) { $0.restSeconds = value } }),
                        in: 0...600, step: 15) {
                    HStack {
                        Text("Rest")
                        Spacer()
                        Text(SetRow.clock(settings.restSeconds ?? 120)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            RowDivider()
            Row {
                Stepper(value: Binding(get: { settings.warmupRestSeconds ?? 60 },
                                       set: { value in store.updateSettings(exercise.id) { $0.warmupRestSeconds = value } }),
                        in: 0...600, step: 15) {
                    HStack {
                        Text("Rest after warm-ups")
                        Spacer()
                        Text(SetRow.clock(settings.warmupRestSeconds ?? 60)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The bars a gym has, in the person's unit.
    static func bars(_ unit: TrainingUnit) -> [Double] {
        unit == .kg ? [0, 10, 15, 20] : [0, 25, 35, 45].map { unit.kilograms($0) }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        if logs.isEmpty {
            CardEmptyBlock("Not done yet. Every workout with it will be here.", symbol: "clock.arrow.circlepath")
        } else {
            ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                CardGroup(log.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(log.name).font(.subheadline.weight(.semibold))
                        ForEach(log.exercises.filter { $0.exerciseID == exerciseID }) { entry in
                            ForEach(Array(entry.sets.filter(\.isDone).enumerated()), id: \.element.id) { i, set in
                                HStack {
                                    Text(set.tag.badge ?? "\(i + 1)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(set.tag == .warmup ? JcTheme.amber : JcTheme.muted)
                                        .frame(width: 22, alignment: .leading)
                                    Text(SetRow.describe(set, kind: entry.kind, unit: unit))
                                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                                        .monospacedDigit()
                                    if !set.records.isEmpty {
                                        Image(systemName: "trophy.fill").font(.caption).foregroundStyle(JcTheme.amber)
                                    }
                                    Spacer()
                                    if let e1rm = set.e1rm {
                                        Text("1RM \(unit.estimate(e1rm))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: Charts

    @ViewBuilder private var charts: some View {
        let kind = exercise?.kind ?? .weightReps
        let options = TrainingMath.ChartMetric.available(for: kind)
        let chosen = metric.flatMap { options.contains($0) ? $0 : nil } ?? options[0]
        let points = TrainingMath.chart(chosen, exerciseID: exerciseID, logs: logs)
            .filter { range.start == nil || $0.date >= range.start! }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    ForEach(options) { option in Button(option.label) { metric = option } }
                } label: {
                    HStack(spacing: 4) {
                        Text(chosen.label).font(.headline)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(JcTheme.accent)
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            if points.count < 2 {
                CardEmptyBlock(points.isEmpty ? "Nothing in this range yet." : "One workout so far — the line starts at the second.",
                               symbol: "chart.xyaxis.line")
                    .frame(height: 200)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Date", point.date), y: .value(chosen.label, value(point.value, chosen)))
                            .foregroundStyle(JcTheme.accent)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", point.date), y: .value(chosen.label, value(point.value, chosen)))
                            .foregroundStyle(JcTheme.accent)
                            .symbolSize(28)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 220)
                if let best = points.map(\.value).max() {
                    Text("Best \(label(best, chosen))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous).strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func value(_ raw: Double, _ metric: TrainingMath.ChartMetric) -> Double {
        switch metric {
        case .e1RM, .heaviest, .volume: return unit.show(raw)
        case .reps, .seconds: return raw
        }
    }

    private func label(_ raw: Double, _ metric: TrainingMath.ChartMetric) -> String {
        switch metric {
        case .e1RM: return "\(unit.estimate(raw)) \(unit.symbol)"
        case .heaviest, .volume: return "\(unit.format(raw)) \(unit.symbol)"
        case .reps: return "\(Int(raw)) reps"
        case .seconds: return SetRow.clock(Int(raw))
        }
    }

    // MARK: Records

    @ViewBuilder private var records: some View {
        let r = TrainingMath.records(exerciseID: exerciseID, in: logs)
        if r == TrainingMath.Records() {
            CardEmptyBlock("Records appear after the first workout with this exercise.", symbol: "trophy")
        } else {
            CardGroup("Personal records") {
                recordRow("Estimated 1RM", r.e1RM.map { "\(unit.estimate($0)) \(unit.symbol)" })
                recordRow("Heaviest weight", r.maxWeight.map { "\(unit.format($0)) \(unit.symbol)" })
                recordRow("Best set volume", r.maxSetVolume.map { "\(unit.format($0)) \(unit.symbol)" })
                recordRow("Best workout volume", r.maxSessionVolume.map { "\(unit.format($0)) \(unit.symbol)" })
                recordRow("Most reps", r.maxReps.map { "\($0)" })
                recordRow("Longest set", r.maxSeconds.map(SetRow.clock))
            }
            if !r.byReps.isEmpty {
                CardGroup("Best at each rep count", footer: "Predicted from your best estimated 1RM. Bold: you have matched or beaten the prediction.") {
                    HStack {
                        Text("Reps").frame(width: 50, alignment: .leading)
                        Spacer()
                        Text("Best").frame(width: 90, alignment: .trailing)
                        Text("Predicted").frame(width: 90, alignment: .trailing)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(1...12, id: \.self) { reps in
                        let row = r.byReps[reps] ?? TrainingMath.RepRecord()
                        let beats = (row.actual ?? 0) >= (row.predicted ?? .infinity) - 0.01
                        HStack {
                            Text("\(reps)").frame(width: 50, alignment: .leading)
                            Spacer()
                            Text(row.actual.map { unit.format($0) } ?? "—")
                                .fontWeight(beats ? .bold : .regular)
                                .foregroundStyle(row.actual == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .frame(width: 90, alignment: .trailing)
                            Text(row.predicted.map { unit.format(TrainingMath.roundToPlates($0, unit: unit)) } ?? "—")
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .font(.system(.subheadline, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    Spacer().frame(height: 8)
                }
            }
        }
    }

    @ViewBuilder private func recordRow(_ title: String, _ value: String?) -> some View {
        if let value {
            Row(minHeight: 44) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                }
            }
        }
    }
}

/// A full photo, loaded like the thumbnails.
private struct ExercisePhoto: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.gray)
            }
        }
        .task { image = await ExerciseImageCache.shared.image(path) }
    }
}

/// Muscles as chips that wrap; the main ones in the accent.
private struct FlowChips: View {
    let items: [(String, Bool)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.1 ? Color.black : JcTheme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(item.1 ? JcTheme.accent : Color.white.opacity(0.1), in: Capsule())
            }
        }
    }
}

/// Lays children out in rows, wrapping at the width offered.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
