import SwiftUI

/// Strong's keypad, not the system keyboard: digits, a step down and up,
/// RPE on reps, plates on a barbell's weight, and Next to walk the sets.
/// The first key after moving to a cell replaces what was there.
struct SetKeypad: View {
    @ObservedObject var session: StrengthSession
    @State private var buffer: String?
    @State private var panel: Panel = .digits

    enum Panel { case digits, rpe, plates }

    private var focus: SetFocus? { session.focus }
    private var entry: (exercise: LoggedExercise, set: LoggedSet, index: Int)? {
        guard let focus, let e = session.log.exercises.first(where: { $0.id == focus.exercise }),
              let i = e.sets.firstIndex(where: { $0.id == focus.set }) else { return nil }
        return (e, e.sets[i], i)
    }

    var body: some View {
        keypad
            // Out here, not on the keypad itself: it has to hear the keypad
            // closing too, or the next cell starts with the last one's digits.
            .onChange(of: session.focus) { _, focus in
                buffer = nil
                panel = .digits
                if focus != nil {
                    // One keyboard at a time: a set cell closes the system one.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                // …and a text field closes this one.
                if session.focus != nil { withAnimation(.snappy) { session.focus = nil } }
            }
    }

    @ViewBuilder private var keypad: some View {
        if let focus, let entry {
            VStack(spacing: 10) {
                HStack {
                    Text(title(focus, entry))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { session.focus = nil }
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(JcTheme.accent)
                            .frame(width: 44, height: 30)
                    }
                    .accessibilityLabel("Hide keypad")
                }
                switch panel {
                case .digits: digits(focus, entry)
                case .rpe: rpe(focus, entry)
                case .plates: plates(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(JcTheme.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(JcTheme.glassBorder).frame(height: 0.5) }
            .transition(.move(edge: .bottom))
        }
    }

    private func title(_ focus: SetFocus, _ entry: (exercise: LoggedExercise, set: LoggedSet, index: Int)) -> String {
        let number = entry.exercise.sets[..<entry.index].filter { $0.tag != .warmup }.count + 1
        let setName = entry.set.tag == .warmup ? "Warm-up" : "Set \(number)"
        let field = SetRow.heading(focus.field, kind: entry.exercise.kind, unit: session.unit).lowercased()
        return "\(entry.exercise.name) · \(setName) · \(field)"
    }

    // MARK: Digits

    private func digits(_ focus: SetFocus, _ entry: (exercise: LoggedExercise, set: LoggedSet, index: Int)) -> some View {
        let decimal = focus.field == .weight || focus.field == .meters
        let side: (String, String, () -> Void)? = focus.field == .reps
            ? ("RPE", "gauge.with.dots.needle.33percent", { panel = .rpe })
            : focus.field == .weight && bar(entry.exercise) != nil ? ("Plates", "circle.grid.2x1", { panel = .plates }) : nil
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                key("1"); key("2"); key("3")
                action("minus", label: "Step down") { step(-1) }
            }
            GridRow {
                key("4"); key("5"); key("6")
                action("plus", label: "Step up") { step(1) }
            }
            GridRow {
                key("7"); key("8"); key("9")
                if let side {
                    action(side.1, label: side.0, text: side.0, perform: side.2)
                } else {
                    Color.clear.frame(height: 48)
                }
            }
            GridRow {
                if decimal { key(".") } else { Color.clear.frame(height: 48) }
                key("0")
                action("delete.left", label: "Delete") { backspace() }
                Button { next() } label: {
                    Text("Next")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.black)
                        .background(JcTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func key(_ digit: String) -> some View {
        Button { type(digit) } label: {
            Text(digit)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.primary)
        }
        .buttonStyle(KeyPress())
    }

    private func action(_ symbol: String, label: String, text: String? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Group {
                if let text {
                    Text(text).font(.system(size: 15, weight: .semibold))
                } else {
                    Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(JcTheme.accent)
            .background(JcTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(KeyPress())
        .accessibilityLabel(label)
    }

    // MARK: RPE and plates

    private func rpe(_ focus: SetFocus, _ entry: (exercise: LoggedExercise, set: LoggedSet, index: Int)) -> some View {
        VStack(spacing: 10) {
            Text("How hard was it? RPE 10 is nothing left; 8 is two more reps in the tank.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Array(stride(from: 6.0, through: 10.0, by: 0.5)), id: \.self) { value in
                    let chosen = entry.set.rpe == value
                    Button {
                        session.setRPE(chosen ? nil : value, set: focus.set, in: focus.exercise)
                        panel = .digits
                    } label: {
                        Text(TrainingUnit.number(value))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(chosen ? .black : .primary)
                            .background(chosen ? JcTheme.accent : Color.white.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(KeyPress())
                }
                Button { panel = .digits } label: {
                    Image(systemName: "number")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(JcTheme.accent)
                        .background(JcTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(KeyPress())
                .accessibilityLabel("Back to numbers")
            }
        }
    }

    private func bar(_ exercise: LoggedExercise) -> Double? {
        session.store.settings(for: exercise.exerciseID).barKg ?? session.exercise(for: exercise)?.equipment.defaultBar(session.unit)
    }

    private func plates(_ entry: (exercise: LoggedExercise, set: LoggedSet, index: Int)) -> some View {
        let unit = session.unit
        let bar = bar(entry.exercise) ?? 0
        let total = entry.set.kg ?? session.previous(entry.set.id, in: entry.exercise.id)?.kg ?? 0
        let result = TrainingMath.plates(total: total, bar: bar, unit: unit)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(unit.format(total)) \(unit.symbol) on a \(unit.format(bar)) \(unit.symbol) bar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Done") { panel = .digits }
                    .buttonStyle(.jcGlass(compact: true))
            }
            Text("Each side")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if result.perSide.isEmpty {
                Text(total <= bar ? "Just the bar." : "No plates make that.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 6) {
                        ForEach(Array(result.perSide.enumerated()), id: \.offset) { _, plate in
                            PlateChip(weight: plate, unit: unit)
                        }
                    }
                }
            }
            if result.remainder > 0 {
                Text("\(TrainingUnit.number(result.remainder)) \(unit.symbol) a side left over — no plate that small.")
                    .font(.caption)
                    .foregroundStyle(JcTheme.amber)
            }
        }
        .frame(minHeight: 200, alignment: .top)
    }

    // MARK: Typing

    private func currentText(_ focus: SetFocus, _ set: LoggedSet) -> String {
        guard let value = session.value(focus.field, of: set) else { return "" }
        if focus.field == .seconds {
            let s = Int(value)
            return String(s / 60) + String(format: "%02d", s % 60)
        }
        return focus.field == .reps ? String(Int(value)) : TrainingUnit.plain(value)
    }

    private func type(_ key: String) {
        guard let focus else { return }
        var text = buffer ?? ""
        if key == "." {
            guard !text.contains(".") else { return }
            if text.isEmpty { text = "0" }
        }
        guard text.count < 7 else { return }
        text += key
        buffer = text
        apply(text, focus)
    }

    private func backspace() {
        guard let focus, let entry else { return }
        var text = buffer ?? currentText(focus, entry.set)
        if !text.isEmpty { text.removeLast() }
        buffer = text
        apply(text, focus)
    }

    private func apply(_ text: String, _ focus: SetFocus) {
        var value = Double(text)
        if focus.field == .seconds, let digits = Int(text) { value = Double(digits / 100 * 60 + digits % 100) }
        session.setValue(text.isEmpty ? nil : value, field: focus.field, set: focus.set, in: focus.exercise)
    }

    private func step(_ direction: Double) {
        guard let focus, let entry else { return }
        let size: Double
        switch focus.field {
        case .weight: size = session.unit.step
        case .reps: size = 1
        case .seconds: size = 5
        case .meters: size = 0.1
        }
        let base = session.value(focus.field, of: entry.set)
            ?? session.previous(entry.set.id, in: entry.exercise.id).flatMap { session.value(focus.field, of: $0) } ?? 0
        session.setValue(max(0, base + direction * size), field: focus.field, set: focus.set, in: focus.exercise)
        buffer = nil
    }

    /// Weight → reps within a set, then the next set not yet done in the
    /// order they are lifted (a superset round by round).
    private func next() {
        guard let focus, let entry else { return }
        let fields = SetRow.fields(for: entry.exercise.kind)
        if let i = fields.firstIndex(of: focus.field), i + 1 < fields.count {
            session.focus = SetFocus(exercise: focus.exercise, set: focus.set, field: fields[i + 1])
            return
        }
        let order = session.orderedSets
        let here = order.firstIndex { $0.exercise == focus.exercise && $0.set == focus.set } ?? -1
        let exercises = session.log.exercises
        for step in order.dropFirst(here + 1) {
            guard let exercise = exercises.first(where: { $0.id == step.exercise }),
                  let set = exercise.sets.first(where: { $0.id == step.set }), !set.isDone || session.mode == .template
            else { continue }
            session.focus = SetFocus(exercise: exercise.id, set: set.id, field: SetRow.fields(for: exercise.kind)[0])
            return
        }
        withAnimation(.snappy) { session.focus = nil }
    }
}

/// A plate as a disc on its edge: taller for heavier.
struct PlateChip: View {
    let weight: Double
    let unit: TrainingUnit

    private var heavy: Double { unit == .kg ? 25 : 45 }

    var body: some View {
        let height = 34 + 58 * min(1, weight / heavy)
        Text(TrainingUnit.number(weight))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 38, height: height)
            .background(JcTheme.accent.opacity(0.55 + 0.45 * min(1, weight / heavy)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("\(TrainingUnit.number(weight)) \(unit.symbol)")
    }
}

/// Keys dip when pressed.
private struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
