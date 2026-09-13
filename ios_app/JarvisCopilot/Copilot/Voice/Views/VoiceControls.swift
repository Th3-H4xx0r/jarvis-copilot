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
                Image(systemName: active ? "xmark" : "mic.fill")
                    .font(.system(size: VoiceControlMetrics.micIcon, weight: .medium))
                    .foregroundStyle(active ? JcTheme.text : Color.white)
                    .frame(width: VoiceControlMetrics.micDiameter,
                           height: VoiceControlMetrics.micDiameter)
                    .jcLiquidGlass(in: Circle(), tint: active ? .clear : JcTheme.primaryBlue)
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
                Image(systemName: symbol)
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
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
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

/// Push-to-talk ⇄ Realtime. Disabled mid-session: switching modes tears the
/// session down, and doing that from under a live turn reads as a crash.
///
/// Flutter has no such control (it hard-codes realtime), so this lives in the
/// settings sheet rather than on the screen.
struct VoiceModeToggle: View {
    let mode: VoiceMode
    let enabled: Bool
    let onChange: (VoiceMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.quality)
            segment(.realtime)
        }
        .frame(maxWidth: 260)
        .background {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            shape.fill(JcTheme.surface)
                .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
        }
        .opacity(enabled ? 1 : 0.5)
    }

    private func segment(_ candidate: VoiceMode) -> some View {
        let active = candidate == mode
        return Button {
            guard enabled, !active else { return }
            onChange(candidate)
        } label: {
            Text(candidate.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? JcTheme.accent : JcTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(JcTheme.accent.opacity(0.16))
                    }
                }
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
