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
    /// The modes this ring offers.
    var modes: [RingInputMode] = RingInputMode.r12
    /// The ring's Keep Alive key: gestures only arrive over a live link, which it decides.
    var keepAliveDevice: String?

    private var footer: String {
        var text = inputs.contains(.shake)
            ? "Tap and shake. Tap twice or three times, about a second apart."
            : "Do a gesture and watch which row lights up."
        if store.wantedMode == .jarvis, let device = keepAliveDevice, !WearableKeepAlive.isOn(device) {
            text += " Keep connection alive is off, so gestures only reach Jarvis while the ring is "
                + "connected for something else — a sync, a measurement or this screen."
        }
        return text
    }

    /// What the stepper shows. Kept locally so the buttons always move, and reconciled with
    /// what the ring reports underneath.
    @State private var wantedSensitivity = 1

    var body: some View {
        CardGroup("Ring inputs", footer: footer) {
            Row {
                Picker("Gestures", selection: Binding(get: { store.wantedMode }, set: onMode)) {
                    ForEach(modes) { Text($0.label).tag($0) }
                }
                .disabled(!ready)
            }
            RowDivider()
            Row {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.wantedMode.detail).font(.caption).foregroundStyle(.secondary)
                    if ready, ringMode != store.wantedMode {
                        Text("The ring is still on \"\(ringMode.label)\".")
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
                        JcIcon("chevron.right").font(.caption).foregroundStyle(.tertiary)
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
                        // The rule, not the reasoning behind it. The measured gap
                        // below is what people actually tune against.
                        Text("How long a single tap waits before running. Leave about a "
                             + "second between taps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let gap = lastPressGap {
                            // The measured gap is the thing to set the window above. Tap twice and
                            // read it, rather than guessing.
                            Text(String(format: "Last two presses: %.1fs apart%@", gap,
                                        gap > store.pressWindow ? " — over the window" : ""))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(gap > store.pressWindow ? AnyShapeStyle(Color.orange)
                                                                         : AnyShapeStyle(.secondary))
                        } else {
                            Text("Tap twice to measure your own timing.")
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
                        JcIcon(shakeArmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(shakeArmed ? Color.green : Color.orange)
                        Text(shakeArmed
                             ? "Armed. Shake firmly; three seconds between shakes."
                             : "Not armed — the ring refuses this on the charger, or with gestures off.")
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
                    Text("Nothing yet. Tap the ring.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(gestureFeed.prefix(6)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            JcIcon(event.kind.icon)
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
        case .press: return JcTheme.accent
        case .shake: return JcTheme.accentAlt
        case .resolved: return .green
        case .ignored: return .orange
        case .ran: return .teal
        }
    }

    /// Says whether the ring took the change, rather than leaving a number that never moves.
    private var sensitivityNote: String {
        guard let sensitivity else { return "Not reported yet." }
        if sensitivity == wantedSensitivity {
            return "Higher needs a firmer tap, and catches fewer stray ones."
        }
        return "The ring still reports \(sensitivity)."
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

/// One-tap versions of a wearable command with an on/off switch (`on: boolean`), so stopping is
/// as easy to pick as starting — "Stop sterilising" next to "Sterilise now".
enum WearableQuickActions {
    struct Quick: Equatable {
        let label: String
        let arguments: [String: String]
    }

    private static let labels: [String: (on: String, off: String)] = [
        "bottle_sterilise": ("Sterilise now", "Stop sterilising"),
    ]

    /// The one-tap names for a command's on and off sides ("Sterilise now" / "Stop sterilising").
    static func names(for skill: String) -> (on: String, off: String) {
        if let named = labels[skill] { return named }
        let words = skill.split(separator: "_").map(String.init)
        let title = (words.count > 1 ? words.dropFirst() : words[...]).joined(separator: " ").capitalized
        return ("\(title) on", "\(title) off")
    }

    /// The boolean a command is switched by: `on`, or `enabled` / `power` where a device names it so
    /// (dashcam recording, light power).
    static let switchKeys = ["on", "enabled", "power"]

    static func actions(for capability: DeviceCapability) -> [Quick] {
        let properties = capability.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
        guard let key = switchKeys.first(where: { properties[$0]?["type"] as? String == "boolean" }) else { return [] }
        // A command that needs more than its switch to run can't be a one-tap.
        let required = Set((capability.inputSchema["required"] as? [String]) ?? []).subtracting([key, "confirm"])
        guard required.isEmpty else { return [] }
        let names = names(for: capability.name)
        // Starting a cycle the device asks to confirm is confirmed by choosing it here.
        let on = properties["confirm"] != nil ? [key: "true", "confirm": "true"] : [key: "true"]
        return [Quick(label: names.on, arguments: on), Quick(label: names.off, arguments: [key: "false"])]
    }
}

/// Uses the exact parameter schema advertised to chat; saves stable target identity. `onServer`:
/// a board the server holds (the Pod, an ESP32 on Wi-Fi), run through the server.
struct RingWearableActionEditor: View {
    let current: RingAction
    let onSave: (RingAction) -> Void
    let deviceID: String
    let model: String
    let capability: DeviceCapability
    var onServer = false
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        Form {
            Section(model) {
                Text(capability.description)
                Text("Device \(deviceID)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Action values") {
                ForEach(SkillArgsForm.fields(from: capability.inputSchema)) { field in
                    SkillArgFieldView(field: field, text: Binding(
                        get: { values[field.key] ?? "" },
                        set: { values[field.key] = $0; error = nil }))
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Save") {
                    do {
                        _ = try SkillArgsForm.validatedArguments(values, schema: capability.inputSchema)
                        onSave(onServer ? .serverDevice(deviceID: deviceID, skill: capability.name, arguments: values)
                                        : .wearable(deviceID: deviceID, skill: capability.name, arguments: values))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .navigationTitle(capability.name.replacingOccurrences(of: "_", with: " ").capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if case .wearable(let target, let skill, let stored) = current, !onServer,
               target == deviceID, skill == capability.name { values = stored }
            else if case .serverDevice(let target, let skill, let stored) = current, onServer,
                    target == deviceID, skill == capability.name { values = stored }
            else {
                let props = capability.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
                for field in SkillArgsForm.fields(from: capability.inputSchema) {
                    if let value = props[field.key]?["default"] { values[field.key] = SkillArgsForm.initialText(value, field: field) }
                    else if field.kind == .boolean && field.required { values[field.key] = "false" }
                }
            }
        }
    }
}
