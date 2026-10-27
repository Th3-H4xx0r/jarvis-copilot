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

/// A live waveform in the state's colour — the island's trailing glyph and the card's corner.
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
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        case "thinking":
            Image(systemName: "ellipsis")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
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

/// Orb, name and state, waveform at the trailing edge. Offline only when it is.
struct JarvisVoiceHeader: View {
    let st: JarvisActivityAttributes.ContentState
    var orb: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            JarvisLiveOrb(size: orb, glow: jcStateColor(st.state))
            VStack(alignment: .leading, spacing: 1) {
                Text("Jarvis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    if !st.connected {
                        Image(systemName: "wifi.slash").font(.system(size: 11, weight: .semibold))
                    }
                    Text(st.connected ? jcVoiceTitle(st.state) : "Offline")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(st.connected && st.state != "idle" ? jcStateColor(st.state) : .white.opacity(0.55))
            }
            Spacer(minLength: 8)
            JarvisVoiceWave(state: st.connected ? st.state : "error", size: 20)
        }
    }
}

/// The Lock Screen / banner card.
struct JarvisVoiceLockScreen: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JarvisVoiceHeader(st: st)
            if let line = jcVoiceLine(st) {
                Text(line)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(st.state == "thinking" ? 0.7 : 0.95))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
