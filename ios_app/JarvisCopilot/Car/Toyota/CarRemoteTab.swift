import SwiftUI

/// Remote: nine tap-and-hold buttons like Toyota's, then Climate and Find.
struct CarRemoteTab: View {
    @ObservedObject var store: ToyotaStore
    var openClimate: () -> Void
    var openFind: () -> Void
    @State private var nudged = false

    private var buttons: [ToyotaCommand] {
        [store.car?.running == true ? .stop : .start, .lock, .unlock,
         .trunkLock, .trunkUnlock, .lights,
         .horn, .buzzer, store.hazardsOn ? .hazardsOff : .hazardsOn]
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(nudged ? "Hold the button to activate" : "Tap and hold to activate")
                .font(.footnote)
                .foregroundStyle(nudged ? JcTheme.amber : .secondary)
                .animation(.easeInOut(duration: 0.2), value: nudged)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            tile(buttons[row * 3 + column])
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            CardGroup {
                NavRow(icon: "fan.fill", title: "Climate", detail: climateSummary, action: openClimate)
                Divider().padding(.leading, 52)
                NavRow(icon: "mappin.and.ellipse", title: "Find", detail: findSummary, action: openFind)
            }
        }
    }

    private func tile(_ command: ToyotaCommand) -> some View {
        ToyotaHoldTile(command: command,
                       available: store.car?.commands.contains(command) ?? false,
                       busy: store.isBusy(command),
                       waiting: store.busy != nil && !store.isBusy(command),
                       outcome: store.outcome(for: command),
                       onShortTap: nudge,
                       onHold: { Task { await store.run(command) } })
    }

    private func nudge() {
        nudged = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            nudged = false
        }
    }

    private var climateSummary: String {
        guard let c = store.car?.climate else { return "Not reported" }
        let temp = c.temp.map { "\(WearableControl.format($0))\(c.unit)" } ?? "—"
        let defrost = [c.defrostFront == true ? "front" : nil, c.defrostRear == true ? "rear" : nil].compactMap { $0 }
        return temp + " · " + (defrost.isEmpty ? "Defrost off" : "Defrost " + defrost.joined(separator: " + "))
    }

    private var findSummary: String {
        guard let location = store.car?.location else { return "No location yet" }
        guard let at = location.at else { return "Last parked" }
        return "Parked " + at.formatted(.relative(presentation: .named))
    }
}

/// A row that opens a sheet.
private struct NavRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row {
                HStack(spacing: 12) {
                    JcIcon(icon, size: 16)
                        .foregroundStyle(JcTheme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.semibold))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    JcIcon("chevron.right", size: 13).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One remote button. A hold of `holdSeconds` fires it (the ring fills while held); a short tap
/// only nudges "hold to activate", so a brush of the screen never honks or unlocks the car.
struct ToyotaHoldTile: View {
    let command: ToyotaCommand
    let available: Bool
    let busy: Bool
    /// Another command is running — one at a time.
    let waiting: Bool
    let outcome: ToyotaStore.Outcome?
    let onShortTap: () -> Void
    let onHold: () -> Void

    static let holdSeconds = 0.6
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(.white.opacity(0.06))
                Circle()
                    .trim(from: 0, to: pressing ? 1 : 0)
                    .stroke(JcTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(pressing ? .linear(duration: Self.holdSeconds) : .easeOut(duration: 0.15), value: pressing)
                if busy {
                    ProgressView()
                } else {
                    JcIcon(command.symbol, size: 21)
                        .foregroundStyle(command == .hazardsOff ? JcTheme.amber : Color.white)
                }
            }
            .frame(width: 56, height: 56)
            Text(command.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(captionColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: 12)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: busy ? JcTheme.accent.opacity(0.35) : .clear)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A tap only nudges (it fails on a scroll and after a completed hold); the hold fires.
        .onTapGesture(perform: onShortTap)
        .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 24) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onHold()
        } onPressingChanged: { down in
            pressing = down
        }
        .opacity(available ? (waiting ? 0.6 : 1) : 0.4)
        .disabled(!available || busy || waiting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title)
        .accessibilityValue(caption)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHold() }
    }

    private var caption: String {
        if busy { return "Working…" }
        if let outcome { return outcome.text }
        if !available { return "Not available" }
        return " "
    }

    private var captionColor: Color {
        guard let outcome else { return .secondary }
        if outcome.pending { return JcTheme.amber }
        return outcome.ok ? JcTheme.success : JcTheme.danger
    }
}
