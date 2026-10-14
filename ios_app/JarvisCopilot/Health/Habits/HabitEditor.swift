import SwiftUI

/// Create or edit a habit: its name, when it was quit, a streak target and a
/// relapse limit (a day or a month).
struct HabitEditor: View {
    let habit: Habit?
    @ObservedObject var store: HabitStore
    @Environment(\.dismiss) private var dismiss

    enum LimitKind: String, CaseIterable, Identifiable {
        case none = "None", day = "Daily", month = "Monthly"
        var id: String { rawValue }
    }

    @State private var name: String
    @State private var startedAt: Date
    @State private var hasTarget: Bool
    @State private var targetDays: Int
    @State private var limitKind: LimitKind
    @State private var limitCount: Int
    @State private var confirmingDelete = false

    init(habit: Habit?, store: HabitStore = .shared) {
        self.habit = habit
        self.store = store
        _name = State(initialValue: habit?.name ?? "")
        _startedAt = State(initialValue: habit?.startedAt ?? Date())
        _hasTarget = State(initialValue: habit.map { $0.goal.streakDays != nil } ?? true)
        _targetDays = State(initialValue: habit?.goal.streakDays ?? 30)
        _limitKind = State(initialValue: habit?.goal.limit.map { $0.per == .day ? .day : .month } ?? LimitKind.none)
        _limitCount = State(initialValue: habit?.goal.limit?.count ?? 1)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    CardGroup("Habit") {
                        Row {
                            TextField("What are you quitting?", text: $name)
                                .submitLabel(.done)
                        }
                        RowDivider()
                        Row {
                            DatePicker("Quit on", selection: $startedAt, in: ...Date(),
                                       displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    CardGroup("Streak target", footer: "Days in a row without a relapse.") {
                        Row {
                            Toggle("Set a target", isOn: $hasTarget.animation(.snappy))
                                .tint(JcTheme.accent)
                        }
                        if hasTarget {
                            RowDivider()
                            Row {
                                Stepper("\(targetDays) day\(targetDays == 1 ? "" : "s")", value: $targetDays, in: 1...3650)
                                    .monospacedDigit()
                            }
                            RowDivider()
                            Row {
                                HStack(spacing: 8) {
                                    ForEach([7, 30, 90, 365], id: \.self) { days in
                                        Button("\(days)d") { targetDays = days }
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(targetDays == days ? JcTheme.accent : JcTheme.text)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(targetDays == days ? JcTheme.accent.opacity(0.22) : Color.white.opacity(0.07),
                                                        in: Capsule())
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    CardGroup("Relapse limit", footer: "The most you allow yourself. Days or months over it show in orange.") {
                        Row {
                            Picker("Limit", selection: $limitKind.animation(.snappy)) {
                                ForEach(LimitKind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        if limitKind != .none {
                            RowDivider()
                            Row {
                                Stepper("At most \(limitCount) a \(limitKind == .day ? "day" : "month")",
                                        value: $limitCount, in: 0...1000)
                                    .monospacedDigit()
                            }
                        }
                    }
                    if habit != nil {
                        Button("Delete Habit", role: .destructive) { confirmingDelete = true }
                            .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .jcScreen(habit == nil ? "New Habit" : "Edit Habit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmed.isEmpty)
                }
            }
            .confirmationDialog("Delete \(habit?.name ?? "this habit")?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete it and all its relapses", role: .destructive) {
                    if let habit { store.delete(habit) }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        var saved = habit ?? Habit(name: trimmed)
        saved.name = String(trimmed.prefix(80))
        saved.startedAt = startedAt.wholeSeconds
        saved.goal = HabitGoal(streakDays: hasTarget ? targetDays : nil,
                               limit: limitKind == .none ? nil
                                   : HabitLimit(per: limitKind == .day ? .day : .month, count: limitCount))
        store.save(saved)
        dismiss()
    }
}

/// Log a relapse that happened earlier — one that was forgotten at the time.
struct HabitPastRelapse: View {
    let habit: Habit
    @ObservedObject var store: HabitStore
    @State private var when = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DatePicker("When", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .tint(JcTheme.accent)
                    .padding(.horizontal, 20)
            }
            .jcScreen("Log a Past Relapse")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        store.log(habit, at: when)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
