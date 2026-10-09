import SwiftUI

/// Controls: the car from above, then every remote command as a round tap-and-hold button.
struct CarControlsScreen: View {
    @ObservedObject var store: ToyotaStore
    @ObservedObject var stage: CarStage
    @State private var nudged = false

    private var commands: [ToyotaCommand] {
        [store.car?.running == true ? .stop : .start, .lock, .unlock,
         .trunkLock, .trunkUnlock, .lights,
         .horn, .buzzer, store.hazardsOn ? .hazardsOff : .hazardsOn]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CarStageView(stage: stage, at: .top)
                    .frame(height: 320)
                Text(nudged ? "Hold the button to activate" : "Tap and hold to activate")
                    .font(.footnote)
                    .foregroundStyle(nudged ? JcTheme.amber : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: nudged)
                if let reason = store.account?.blockedReason {
                    Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
                Grid(horizontalSpacing: 6, verticalSpacing: 10) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<3, id: \.self) { column in button(commands[row * 3 + column]) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .opacity(store.isSignedIn ? 1 : 0.45)
                .disabled(!store.isSignedIn)
            }
            .padding(.bottom, 24)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func button(_ command: ToyotaCommand) -> some View {
        ToyotaRoundButton(command: command,
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
}

/// A round glass button's face: the icon in a circle, its name, and a line under it.
struct ToyotaRoundFace: View {
    let symbol: String
    let title: String
    let caption: String
    var tint: Color = .white
    var captionColor: Color = .secondary
    var busy = false
    /// 0…1: the hold's progress ring.
    var ring: CGFloat = 0
    var ringAnimation: Animation? = nil

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(JcTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(ringAnimation, value: ring)
                if busy {
                    ProgressView()
                } else {
                    JcIcon(symbol, size: 22).foregroundStyle(tint)
                }
            }
            .frame(width: 64, height: 64)
            .jcLiquidGlass(in: Circle(), tint: busy ? JcTheme.accent.opacity(0.35) : .clear)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(captionColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A remote command as a round button. Holding it for `holdSeconds` fires it (the ring fills while
/// held); a short tap only nudges "hold to activate", so a brush of the screen never honks or
/// unlocks the car.
struct ToyotaRoundButton: View {
    let command: ToyotaCommand
    var title: String? = nil
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
        ToyotaRoundFace(symbol: command.symbol, title: title ?? command.title, caption: caption,
                        tint: command == .hazardsOff ? JcTheme.amber : .white,
                        captionColor: captionColor, busy: busy,
                        ring: pressing ? 1 : 0,
                        ringAnimation: pressing ? .linear(duration: Self.holdSeconds) : .easeOut(duration: 0.15))
            .contentShape(Rectangle())
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
            .accessibilityLabel(title ?? command.title)
            .accessibilityValue(caption.trimmingCharacters(in: .whitespaces))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if available && !busy && !waiting { onHold() } }
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
