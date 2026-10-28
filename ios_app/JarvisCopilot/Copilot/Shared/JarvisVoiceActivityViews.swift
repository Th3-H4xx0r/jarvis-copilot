import SwiftUI

// The voice Live Activity in Apple's own register (Music Recognition, Siri): the pulsing
// orb and what Jarvis is doing, the ✕ (or a mic at rest), and the exchange — his question
// small over Jarvis's answer. Shared with the app so render tests can draw it.

/// "Listening…", "Thinking…", …; idle invites a tap.
func jcVoiceTitle(_ state: String) -> String {
    switch state {
    case "listening": return "Listening…"
    case "thinking": return "Thinking…"
    case "speaking": return "Speaking…"
    case "error": return "Couldn't reach Jarvis"
    default: return "Tap to talk"
    }
}

/// The state's glyph in its colour — the island's trailing mark and the card's
/// corner. Still: a Live Activity plays no symbol effect (the pulse is the motion).
struct JarvisVoiceWave: View {
    let state: String
    var size: CGFloat = 18

    var body: some View {
        let tint = jcStateColor(state)
        switch state {
        case "listening", "speaking":
            Image(systemName: "waveform")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
        case "thinking":
            Image(systemName: "ellipsis")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
        case "error":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(tint)
        default:
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// The orb with its pulse: while Jarvis listens, thinks or speaks a ring spreads out
/// from it and fades, in the state's colour; at rest it's the orb alone, the same
/// size, so nothing jumps.
struct JarvisOrbBadge: View {
    let state: String
    var since: Double = 0
    /// The pulse's reach; the orb is `JarvisPulse.orbShare` of it.
    var size: CGFloat

    var body: some View {
        ZStack {
            if let color = JarvisPulse.color(state) {
                JarvisPulse(color: color, size: size, since: since)
            }
            JarvisLiveOrb(size: size * JarvisPulse.orbShare, glow: jcStateColor(state))
        }
        .frame(width: size, height: size)
    }
}

extension JarvisOrbBadge {
    init(st: JarvisActivityAttributes.ContentState, size: CGFloat) {
        self.init(state: st.connected ? st.state : "error", since: st.stateSince, size: size)
    }
}

/// The ✕ that ends the talk, in a tinted circle (Music Recognition's stop).
struct JarvisStopButton: View {
    var tint: Color
    var size: CGFloat = 40

    var body: some View {
        Button(intent: StopJarvisVoiceIntent()) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

/// A talk is on: the island offers its ✕.
func jcVoiceActive(_ st: JarvisActivityAttributes.ContentState) -> Bool {
    ["listening", "thinking", "speaking"].contains(st.state)
}

/// The ✕'s tint: the state's colour, neutral while offline.
func jcStopTint(_ st: JarvisActivityAttributes.ContentState) -> Color {
    st.connected ? jcStateColor(st.state) : .white
}

/// The header's words: what Jarvis is doing, or just "Jarvis" at rest.
func jcVoiceHeader(_ st: JarvisActivityAttributes.ContentState) -> String {
    guard st.connected else { return "Offline" }
    switch st.state {
    case "listening", "thinking", "speaking", "error": return jcVoiceTitle(st.state)
    default: return "Jarvis"
    }
}

/// The ✕ during a talk; at rest a mic that starts one right there (the Action
/// button's talk); the state's glyph beside the ✕.
struct JarvisVoiceControls: View {
    let st: JarvisActivityAttributes.ContentState
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            if jcVoiceActive(st) {
                JarvisVoiceWave(state: st.connected ? st.state : "error", size: size * 0.45)
                JarvisStopButton(tint: jcStopTint(st), size: size)
            } else if #available(iOS 18.0, *) {
                Button(intent: TalkToJarvisHereIntent()) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Circle().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to Jarvis")
            }
        }
    }
}

/// The exchange, Siri's way: once Jarvis answers, his question small and grey over
/// the answer; before that, his words (or what Jarvis is doing) as the main line.
struct JarvisExchange: View {
    let st: JarvisActivityAttributes.ContentState
    var answerSize: CGFloat = 16
    var answerLines = 2

    var body: some View {
        let said = st.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = st.activity.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 3) {
            if !reply.isEmpty {
                if !said.isEmpty {
                    Text(said)
                        .font(.system(size: answerSize - 3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Text(reply)
                    .font(.system(size: answerSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(st.state == "thinking" ? 0.75 : 0.96))
                    .lineLimit(answerLines)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !said.isEmpty {
                Text(said)
                    .font(.system(size: answerSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(st.state == "listening" ? 0.96 : 0.7))
                    .lineLimit(answerLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Whether there's an exchange to show under the header.
func jcHasExchange(_ st: JarvisActivityAttributes.ContentState) -> Bool {
    !st.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !st.activity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// The Lock Screen / banner card: the island's header row, the exchange under it.
struct JarvisVoiceLockScreen: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                JarvisOrbBadge(st: st, size: 46)
                Text(jcVoiceHeader(st))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                JarvisVoiceControls(st: st, size: 38)
            }
            if jcHasExchange(st) {
                JarvisExchange(st: st, answerSize: 17, answerLines: 3)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
