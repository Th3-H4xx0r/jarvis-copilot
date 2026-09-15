import SwiftUI

/// How big the controls are. The phone's row is 108 pt tall with a 68 pt mic
/// button, which is right for a hand at arm's length and a full screen to spend.
/// The Mac panel is a menubar popover well under half that height, read at desk
/// distance and clicked with a pointer, so the same row eats a quarter of it.
enum VoiceControlMetrics {
    #if JC_MAC_VOICE
    static let rowHeight: CGFloat = 76
    static let micDiameter: CGFloat = 50
    static let micIcon: CGFloat = 19
    static let micSlot: CGFloat = 66
    static let ghostDiameter: CGFloat = 38
    static let ghostIcon: CGFloat = 15
    static let ghostSlot: CGFloat = 58
    static let labelSize: CGFloat = 10.5
    static let stackSpacing: CGFloat = 5
    static let sideInset: CGFloat = 14
    #else
    static let rowHeight: CGFloat = 108
    static let micDiameter: CGFloat = 68
    static let micIcon: CGFloat = 25
    static let micSlot: CGFloat = 86
    static let ghostDiameter: CGFloat = 50
    static let ghostIcon: CGFloat = 20
    static let ghostSlot: CGFloat = 76
    static let labelSize: CGFloat = 12
    static let stackSpacing: CGFloat = 8
    static let sideInset: CGFloat = 32
    #endif
}

/// Labeled controls keep stopping a session distinct from submitting a turn.
struct VoiceControls: View {
    let state: VoiceState
    let isActive: Bool
    let muted: Bool
    let onPrimary: () -> Void
    let onMute: () -> Void
    let onFinish: () -> Void
    let onInterrupt: () -> Void

    static let height: CGFloat = VoiceControlMetrics.rowHeight

    var body: some View {
        HStack(alignment: .center) {
            VoiceGhostCircle(symbol: muted ? "mic.slash" : "mic",
                             highlighted: muted,
                             label: muted ? "Unmute" : "Mute",
                             action: isActive ? onMute : nil)
            Spacer(minLength: 16)
            VoiceMicButton(active: isActive, action: onPrimary)
            Spacer(minLength: 16)
            if isActive && state == .listening {
                VoiceGhostCircle(symbol: "arrow.up", label: "Send", action: muted ? nil : onFinish)
            } else if isActive && (state == .speaking || state == .thinking) {
                VoiceGhostCircle(symbol: "hand.raised", label: "Interrupt", action: onInterrupt)
            } else {
                VoiceGhostCircle(symbol: "arrow.up", label: "Send", action: nil)
            }
        }
        .frame(maxWidth: 320)
        .frame(height: Self.height)
        .padding(.horizontal, VoiceControlMetrics.sideInset)
        .frame(maxWidth: .infinity)
    }
}

struct VoiceMicButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: VoiceControlMetrics.stackSpacing) {
                JcIcon(active ? "xmark" : "mic.fill")
                    .font(.system(size: VoiceControlMetrics.micIcon, weight: .medium))
                    .foregroundStyle(active ? JcTheme.text : JcTheme.accent)
                    .frame(width: VoiceControlMetrics.micDiameter,
                           height: VoiceControlMetrics.micDiameter)
                    // Clear glass, not a tinted disc: the accent is the glyph.
                    .jcLiquidGlass(in: Circle())
                Text(active ? "End" : "Start")
                    .font(.system(size: VoiceControlMetrics.labelSize, weight: .medium))
                    .foregroundStyle(JcTheme.text)
            }
            .frame(width: VoiceControlMetrics.micSlot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        // `children: .ignore` collapses the label+icon stack into one element,
        // and on macOS that element reports as a plain group rather than a
        // button, so VoiceOver and automation see something unpressable. Stating
        // the trait is the documented answer; it is a no-op on iOS, where the
        // element is already a button. (Not yet confirmed to change the AX role
        // on macOS — the label is exposed either way.)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(active ? "End conversation" : "Start talking")
    }
}

struct VoiceGhostCircle: View {
    let symbol: String
    var highlighted = false
    let label: String
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            VStack(spacing: VoiceControlMetrics.stackSpacing) {
                JcIcon(symbol)
                    .font(.system(size: VoiceControlMetrics.ghostIcon, weight: .medium))
                    .foregroundStyle(highlighted ? JcTheme.cyan : JcTheme.text)
                    .frame(width: VoiceControlMetrics.ghostDiameter,
                           height: VoiceControlMetrics.ghostDiameter)
                    .jcLiquidGlass(in: Circle(), tint: highlighted ? JcTheme.cyan.opacity(0.25) : .clear)
                Text(label)
                    .font(.system(size: VoiceControlMetrics.labelSize, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
            }
            .frame(width: VoiceControlMetrics.ghostSlot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(action == nil ? 0.35 : 1)
        .disabled(action == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }
}

/// "Try on server" — shown under the reply after an ON-DEVICE voice answer, to
/// re-run that turn against the server (which can give a better one). Port of
/// `_TryServerChip`.
struct VoiceTryServerChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                JcIcon("icloud.and.arrow.up", size: 13, weight: .medium)
                Text("Try on server")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(JcTheme.cyan)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(JcTheme.cyan.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.cyan.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A choice drawn as cards side by side: an icon, a name, and a line on what it
/// does. Styled like the More tiles — cyan glyphs on the app's glass cards — with
/// the chosen card lit in cyan. Replaces the bare text segments these settings
/// used to be: a word like "Server" said nothing about what choosing it meant.
struct VoiceOptionCards<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let symbol: String
        let title: String
        let detail: String
        var id: Value { value }
    }

    let options: [Option]
    let selection: Value
    let enabled: Bool
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(options) { card($0) }
        }
        .opacity(enabled ? 1 : 0.55)
    }

    private func card(_ option: Option) -> some View {
        let selected = option.value == selection
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            guard enabled, !selected else { return }
            onSelect(option.value)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    JcIcon(option.symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(JcTheme.cyan.opacity(selected ? 1 : 0.7))
                        .frame(width: 32, height: 32)
                    Spacer(minLength: 4)
                    JcIcon(selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? JcTheme.cyan : JcTheme.muted.opacity(0.45))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(option.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Color.white.opacity(selected ? 0.07 : 0.045), in: shape)
            .overlay(shape.strokeBorder(selected ? JcTheme.cyan.opacity(0.55) : JcTheme.glassBorder,
                                        lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension VoiceOptionCards where Value == VoiceMode {
    static var modes: [Option] {
        [Option(value: .realtime, symbol: "waveform",
                title: VoiceMode.realtime.label, detail: "Talk naturally. It listens and answers as you go."),
         Option(value: .quality, symbol: "hand.tap",
                title: VoiceMode.quality.label, detail: "Tap to ask, tap again to send.")]
    }
}

extension VoiceOptionCards where Value == VoiceTranscription {
    static var transcriptions: [Option] {
        #if JC_MAC_VOICE
        let device = "Private: audio never leaves this Mac."
        let symbol = "laptopcomputer"
        #else
        let device = "Private: audio never leaves this iPhone."
        let symbol = "iphone"
        #endif
        return [Option(value: .onDevice, symbol: symbol,
                       title: VoiceTranscription.onDevice.label, detail: device),
                Option(value: .server, symbol: "server.rack",
                       title: VoiceTranscription.server.label, detail: "Your server's speech model transcribes.")]
    }
}

/// A small heading over a set of option cards.
struct VoiceOptionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(JcTheme.text.opacity(0.9))
            .padding(.leading, 4)
            .padding(.bottom, 8)
    }
}
