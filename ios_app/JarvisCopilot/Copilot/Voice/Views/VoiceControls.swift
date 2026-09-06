import SwiftUI

/// Labeled controls keep stopping a session distinct from submitting a turn.
struct VoiceControls: View {
    let state: VoiceState
    let isActive: Bool
    let muted: Bool
    let onPrimary: () -> Void
    let onMute: () -> Void
    let onFinish: () -> Void
    let onInterrupt: () -> Void

    static let height: CGFloat = 108

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
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

struct VoiceMicButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: active ? "xmark" : "mic.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(active ? JcTheme.text : Color.white)
                    .frame(width: 68, height: 68)
                    .jcLiquidGlass(in: Circle(), tint: active ? .clear : JcTheme.primaryBlue)
                Text(active ? "End" : "Start")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.text)
            }
            .frame(width: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
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
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(highlighted ? JcTheme.cyan : JcTheme.text)
                    .frame(width: 50, height: 50)
                    .jcLiquidGlass(in: Circle(), tint: highlighted ? JcTheme.cyan.opacity(0.25) : .clear)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(action == nil ? 0.35 : 1)
        .disabled(action == nil)
        .accessibilityElement(children: .ignore)
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

/// The quiet state echo under the orb, where the reply lands before there is
/// one: `Text(state.label)` at 13 pt / w700 / 1.6 tracking in the state's
/// colour. Flutter shows this as plain text, NOT a pill.
struct VoiceStatusLabel: View {
    let state: VoiceState
    let toolStatus: String?

    var body: some View {
        Text(toolStatus?.isEmpty == false ? toolStatus! : state.label)
            .font(.system(size: 13, weight: .bold))
            .kerning(1.6)
            .foregroundStyle(voiceStateColor(state))
            .multilineTextAlignment(.center)
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

/// The frosted state pill: the tool the server is running, else the state name.
/// Kept for the Live Activity / island surfaces; the Voice screen itself uses the
/// unboxed ``VoiceStatusLabel``, as the Flutter page does.
struct VoiceStatusPill: View {
    let state: VoiceState
    let toolStatus: String?

    var body: some View {
        Text((toolStatus?.isEmpty == false ? toolStatus! : state.label).uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(1.8)
            .foregroundStyle(voiceStateColor(state))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

/// The devices strip — which of the user's devices Jarvis can currently see. Same
/// list the Live Activity shows (`VoiceStore.deviceKinds`). Not on the Flutter
/// voice screen; kept for the sheets that do show it.
struct VoiceDeviceRow: View {
    let kinds: [String]

    var body: some View {
        if kinds.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                    Image(systemName: voiceDeviceSymbol(kind))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .accessibilityLabel("\(kinds.count) devices online")
        }
    }
}
