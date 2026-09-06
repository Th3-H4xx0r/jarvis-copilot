import SwiftUI

/// The bottom control row: mute on the left, the big mic in the middle,
/// Done/Interrupt on the right. Port of `_Controls` in `voice_page.dart`
/// (`EdgeInsets.fromLTRB(36, 4, 36, 4)`, `spaceBetween`).
struct VoiceControls: View {
    let state: VoiceState
    let isActive: Bool
    let muted: Bool
    let onPrimary: () -> Void
    let onMute: () -> Void
    let onFinish: () -> Void
    let onInterrupt: () -> Void

    /// 88 pt button + 4 pt of padding top and bottom — what the page reserves
    /// under the stage so the orb block can't grow into it.
    static let height: CGFloat = 96

    var body: some View {
        HStack {
            // Mute — only live while a session is.
            VoiceGhostCircle(symbol: muted ? "mic.slash" : "mic",
                             highlighted: muted,
                             label: muted ? "Unmute" : "Mute",
                             action: isActive ? onMute : nil)
            Spacer(minLength: 0)
            VoiceMicButton(active: isActive, action: onPrimary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 4)
    }

    /// Done while listening, Interrupt while the assistant has the floor. Idle
    /// shows the same disabled check the slot turns into, so the glyph doesn't
    /// jump to something unrelated when a turn starts.
    @ViewBuilder
    private var trailing: some View {
        if isActive && state == .listening {
            VoiceGhostCircle(symbol: "checkmark", label: "Done", action: onFinish)
        } else if isActive && (state == .speaking || state == .thinking) {
            VoiceGhostCircle(symbol: "stop.fill", label: "Interrupt", action: onInterrupt)
        } else {
            VoiceGhostCircle(symbol: "checkmark", label: "Done", action: nil)
        }
    }
}

/// The big central mic — a glossy solid-blue 66 pt disc inside a faint 88 pt
/// ring, matching `_MicButton`. Shows a stop glyph while a session is running.
struct VoiceMicButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0x2E / 255.0), lineWidth: 1.2)
                    .frame(width: 88, height: 88)
                Circle()
                    // Flutter's `radius: 1.05` is a fraction of the box's short
                    // side, so the gradient runs past the disc's own edge.
                    .fill(RadialGradient(
                        stops: [.init(color: Color(jcHex: 0x6FB0FF), location: 0),
                                .init(color: Color(jcHex: 0x2E6BFF), location: 0.55),
                                .init(color: Color(jcHex: 0x1E57DC), location: 1)],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0, endRadius: 66 * 1.05))
                    .frame(width: 66, height: 66)
                    .shadow(color: JcTheme.primaryBlue.opacity(0.4), radius: 14)
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "Stop" : "Start talking")
    }
}

/// A small frosted ghost circle for the side actions (`_GhostCircle`).
struct VoiceGhostCircle: View {
    let symbol: String
    var highlighted: Bool = false
    let label: String
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(highlighted ? JcTheme.accent : JcTheme.text)
                .frame(width: 52, height: 52)
                .background(highlighted ? JcTheme.accent.opacity(0.18) : JcTheme.glassFill,
                            in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(action == nil ? 0.4 : 1)
        .disabled(action == nil)
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
