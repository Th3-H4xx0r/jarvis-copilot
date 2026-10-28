import SwiftUI

// The voice Live Activity in Apple's own register (Phone, Siri, Shazam): the animated orb,
// what Jarvis is doing, a live waveform, and the latest words in large type — no boxes, no
// labels, no device strip. Shared with the app so render tests can draw it.

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

/// The one line worth reading: Jarvis's reply (or what he's doing) once he answers, your
/// words while you talk.
func jcVoiceLine(_ st: JarvisActivityAttributes.ContentState) -> String? {
    let said = st.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let reply = st.activity.trimmingCharacters(in: .whitespacesAndNewlines)
    switch st.state {
    case "thinking", "speaking", "error": return reply.isEmpty ? (said.isEmpty ? nil : "“\(said)”") : reply
    default: return said.isEmpty ? (reply.isEmpty ? nil : reply) : "“\(said)”"
    }
}

/// The state's short name, for the small label over the words.
func jcVoiceLabel(_ state: String) -> String {
    switch state {
    case "listening": return "Listening"
    case "thinking": return "Thinking"
    case "speaking": return "Jarvis"
    case "error": return "Couldn't reach Jarvis"
    default: return "Jarvis"
    }
}

/// The state's glyph in its colour — the island's trailing mark and the card's
/// corner. Still: a Live Activity plays no symbol effect (the ring is the motion).
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

/// The expanded island's and the card's text: the state's small label over the
/// latest words, or — before there are any — the state itself, large.
struct JarvisVoiceText: View {
    let st: JarvisActivityAttributes.ContentState
    var wordsSize: CGFloat = 17

    var body: some View {
        let tint = st.connected && st.state != "idle" ? jcStateColor(st.state) : .white.opacity(0.6)
        VStack(alignment: .leading, spacing: 2) {
            if !st.connected {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.system(size: wordsSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            } else if let line = jcVoiceLine(st) {
                Text(jcVoiceLabel(st.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(line)
                    .font(.system(size: wordsSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(st.state == "thinking" ? 0.72 : 0.96))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(jcVoiceTitle(st.state))
                    .font(.system(size: wordsSize + 2, weight: .semibold))
                    .foregroundStyle(st.state == "idle" ? .white : tint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Lock Screen / banner card: the ringed orb, the text beside it, the state's
/// glyph at the trailing edge.
struct JarvisVoiceLockScreen: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            JarvisOrbBadge(st: st, size: 58)
            JarvisVoiceText(st: st)
            if jcVoiceActive(st) {
                JarvisStopButton(tint: jcStopTint(st), size: 38)
            } else {
                JarvisVoiceWave(state: st.connected ? st.state : "error", size: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
