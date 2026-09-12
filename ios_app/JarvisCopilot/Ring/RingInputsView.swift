import SwiftUI

/// What each tap, swipe and press on the ring runs. Replaces the ring's own
/// music/video/camera modes: Jarvis takes the input and runs your action instead.
struct RingInputsSection: View {
    @ObservedObject var store: RingInputStore
    let ready: Bool
    let lastInput: RingInputEvent?
    /// Only the inputs this ring can produce.
    let inputs: [RingInput]
    /// What the ring actually took, read back from it.
    let ringMode: RingInputMode
    let sensitivity: Int?
    /// The gap between the ring's last two presses, as measured. The only honest way to pick a
    /// window: the ring's reporting delay is not the speed you tapped at.
    let lastPressGap: TimeInterval?
    /// Whether the ring acknowledged arming its shake detector.
    let shakeArmed: Bool
    /// The raw gesture stream, newest first.
    let gestureFeed: [RingGestureEvent]
    let onMode: (RingInputMode) -> Void
    let onSensitivity: (Int) -> Void

    /// What the stepper shows. Kept locally so the buttons always move, and reconciled with
    /// what the ring reports underneath.
    @State private var wantedSensitivity = 1

    var body: some View {
        CardGroup("Ring inputs",
                  footer: inputs.contains(.shake)
                      ? "This ring feels two things: a tap and a shake. Tap it two or three times — "
                        + "about a second apart, it cannot feel them faster — for the double and "
                        + "triple, the way a one-button remote works."
                      : "Do a gesture and watch which row says it was just seen, then set that one.") {
            Row {
                Picker("Gestures", selection: Binding(get: { store.wantedMode }, set: onMode)) {
                    ForEach(RingInputMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!ready)
            }
            RowDivider()
            Row {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.wantedMode.detail).font(.caption).foregroundStyle(.secondary)
                    if ready, ringMode != store.wantedMode {
                        Text("The ring is on \"\(ringMode.label)\" — reconnect or pick again if this sticks.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(inputs.enumerated()), id: \.element.id) { _, input in
                RowDivider()
                NavigationLink {
                    RingActionPicker(store: store, input: input)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(input.label).font(.subheadline)
                                if let seen = seenLabel(input) {
                                    Text(seen)
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(store.action(for: input).summary)
                                .font(.caption)
                                .foregroundStyle(store.action(for: input).isSet ? AnyShapeStyle(.secondary)
                                                                                : AnyShapeStyle(.tertiary))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            // Shown whenever the ring can do multi-press, not only once something is bound to it:
            // the window is what you tune while trying a double press out.
            if inputs.contains(.doublePress) {
                RowDivider()
                Row {
                    Picker("Wait for a second press",
                           selection: Binding(get: { store.pressWindow }, set: store.setPressWindow)) {
                        ForEach(RingInputStore.pressWindows, id: \.self) { seconds in
                            Text(String(format: "%.1fs", seconds)).tag(seconds)
                        }
                    }
                }
                RowDivider()
                Row {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Leave about a second between taps: the ring stops listening for one "
                             + "after every tap it reports, so anything faster reaches Jarvis as a "
                             + "single press. A double or triple runs the moment its last tap lands; "
                             + "a single press waits this long first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let gap = lastPressGap {
                            // The measured gap is the thing to set the window above. Tap twice and
                            // read it, rather than guessing.
                            Text(String(format: "Last two presses arrived %.1fs apart%@", gap,
                                        gap > store.pressWindow ? " — longer than the window above" : ""))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(gap > store.pressWindow ? AnyShapeStyle(Color.orange)
                                                                         : AnyShapeStyle(.secondary))
                        } else {
                            Text("Tap the ring twice to see how far apart it reports them.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if store.usesShake {
                RowDivider()
                Row {
                    HStack(spacing: 8) {
                        Image(systemName: shakeArmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(shakeArmed ? Color.green : Color.orange)
                        Text(shakeArmed
                             ? "Shake detector armed. Shake your hand firmly; it waits three seconds "
                               + "between shakes."
                             : "Shake detector not armed — the ring refuses this while it is on the "
                               + "charger, and while gestures are off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if sensitivity != nil {
                RowDivider()
                Row {
                    VStack(alignment: .leading, spacing: 4) {
                        // Driven from local state: the value shown used to come straight from the
                        // parent, so it never moved unless the ring's read-back landed — which
                        // made the buttons look dead even when the write went out.
                        Stepper("Gesture sensitivity \(wantedSensitivity)",
                                value: Binding(get: { wantedSensitivity },
                                               set: { value in
                                                   wantedSensitivity = value
                                                   onSensitivity(value)
                                               }),
                                in: 1...10)
                        Text(sensitivityNote)
                            .font(.caption2)
                            .foregroundStyle(sensitivity == wantedSensitivity ? AnyShapeStyle(.secondary)
                                                                              : AnyShapeStyle(Color.orange))
                    }
                }
                .disabled(!ready)
            }
            if store.wantedMode == .jarvis {
                RowDivider()
                monitor
            }
        }
        .onAppear { wantedSensitivity = sensitivity ?? 1 }
        .onChange(of: sensitivity) { _, value in wantedSensitivity = value ?? wantedSensitivity }
    }

    /// What the ring actually sent, newest first.
    ///
    /// The tap and shake detectors share one accelerometer and trip each other, so when a
    /// gesture "does not work" this is the only way to see which one the ring really reported —
    /// and whether a second tap arrived at all, or the ring simply never sent one.
    @ViewBuilder private var monitor: some View {
        Row {
            VStack(alignment: .leading, spacing: 8) {
                Text("What the ring is sending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if gestureFeed.isEmpty {
                    Text("Nothing yet. Tap the ring and watch this fill in.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(gestureFeed.prefix(6)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: event.kind.icon)
                                .font(.caption2)
                                .foregroundStyle(tint(event.kind))
                                .frame(width: 14)
                            Text(event.title).font(.caption.weight(.medium))
                            Text(event.detail).font(.caption2).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(event.date, style: .relative)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ kind: RingGestureEvent.Kind) -> Color {
        switch kind {
        case .press: return .blue
        case .shake: return .purple
        case .resolved: return .green
        case .ignored: return .orange
        }
    }

    /// Says whether the ring took the change, rather than leaving a number that never moves.
    private var sensitivityNote: String {
        guard let sensitivity else { return "The ring hasn't reported this yet." }
        if sensitivity == wantedSensitivity {
            return "Higher needs a firmer tap, which cuts out stray triggers from ordinary hand movement."
        }
        return "The ring still reports \(sensitivity) — it may not have taken the change."
    }

    /// "just seen" on the row the ring last sent, so the right one is obvious.
    private func seenLabel(_ input: RingInput) -> String? {
        guard let lastInput, lastInput.input == input else { return nil }
        let seconds = Int(Date().timeIntervalSince(lastInput.date))
        if seconds < 5 { return "just seen" }
        if seconds < 60 { return "seen \(seconds)s ago" }
        if seconds < 3600 { return "seen \(seconds / 60)m ago" }
        return nil
    }
}

/// Picks what one input does: a prompt Jarvis runs, or one of the phone's own actions.
struct RingActionPicker: View {
    @ObservedObject var store: RingInputStore
    let input: RingInput

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var selected: String?
    @State private var value = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CardGroup("Ask Jarvis", footer: "Runs as a Jarvis turn with every tool it has — \"turn off the "
                    + "lights\", \"text Mum I'm on my way\", \"what's my next meeting\".") {
                    Row {
                        TextField("What should Jarvis do?", text: $prompt, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    RowDivider()
                    Row {
                        Button("Use this prompt") { save(.prompt(prompt)) }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                ForEach(RingActionCatalogue.groups, id: \.self) { group in
                    CardGroup(group) {
                        let options = RingActionCatalogue.options.filter { $0.group == group }
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { RowDivider() }
                            optionRow(option)
                        }
                    }
                }

                CardGroup("Off") {
                    Row {
                        Button("Do nothing", role: .destructive) { save(.none) }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(input.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func optionRow(_ option: RingActionOption) -> some View {
        Row {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    selected = option.id
                    value = option.arguments[option.parameter?.key ?? ""] ?? ""
                    if option.parameter == nil { save(.skill(id: option.id, arguments: [:])) }
                } label: {
                    HStack {
                        Text(option.label).font(.subheadline)
                        Spacer(minLength: 0)
                        if isCurrent(option) {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let note = option.note, selected == option.id {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if let parameter = option.parameter, selected == option.id {
                    HStack {
                        TextField(parameter.placeholder, text: $value)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Save") { save(.skill(id: option.id, arguments: [parameter.key: value])) }
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func isCurrent(_ option: RingActionOption) -> Bool {
        if case .skill(let id, _) = store.action(for: input) { return id == option.id }
        return false
    }

    private func load() {
        switch store.action(for: input) {
        case .prompt(let text):
            prompt = text
        case .skill(let id, let arguments):
            selected = id
            value = RingActionCatalogue.option(id)?.parameter.flatMap { arguments[$0.key] } ?? ""
        case .none:
            break
        }
    }

    private func save(_ action: RingAction) {
        store.set(action, for: input)
        dismiss()
    }
}
