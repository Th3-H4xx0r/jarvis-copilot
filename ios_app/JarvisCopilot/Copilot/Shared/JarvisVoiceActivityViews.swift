import SwiftUI
import UIKit

// The voice Live Activity, centred the way Siri's is (his pick, 2026-10-27, "3 ·
// Centered"): the pulsing orb leading and a glass stop trailing, then what Jarvis is
// doing with a running timer, his words, and Jarvis's answer — all centred under them.
// One colour, the app accent; the state is said in words. Shared with the app so
// render tests can draw it.

/// The state in a word; at rest, just "Jarvis".
func jcVoiceTitle(_ state: String) -> String {
    switch state {
    case "listening": return "Listening"
    case "thinking": return "Thinking"
    case "speaking": return "Speaking"
    case "error": return "Couldn't reach Jarvis"
    default: return "Jarvis"
    }
}

/// A talk is on: the island offers its stop and runs its timer.
func jcVoiceActive(_ st: JarvisActivityAttributes.ContentState) -> Bool {
    st.connected && ["listening", "thinking", "speaking"].contains(st.state)
}

/// The island's one colour: the accent while a talk is on, red for an error, a
/// quiet white at rest or offline.
func jcVoiceTint(_ st: JarvisActivityAttributes.ContentState) -> Color {
    guard st.connected else { return .white.opacity(0.6) }
    switch st.state {
    case "listening", "thinking", "speaking": return JcAccent.color
    case "error": return jcStateColor("error")
    default: return .white.opacity(0.6)
    }
}

/// Whether there are words for the exchange (his, or Jarvis's).
func jcVoiceHasWords(_ st: JarvisActivityAttributes.ContentState) -> Bool {
    !st.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !st.activity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// When the current state began, for the timers (now when unknown).
func jcVoiceSince(_ st: JarvisActivityAttributes.ContentState) -> Date {
    st.stateSince > 0 ? Date(timeIntervalSince1970: st.stateSince) : Date()
}

/// The orb with its pulse: while Jarvis listens, thinks or speaks a ring spreads out
/// from it and fades; at rest it's the orb alone, the same size, so nothing jumps.
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
            JarvisOrbArt(size: size * JarvisPulse.orbShare)
        }
        .frame(width: size, height: size)
    }
}

extension JarvisOrbBadge {
    init(st: JarvisActivityAttributes.ContentState, size: CGFloat) {
        self.init(state: st.connected ? st.state : "error", since: st.stateSince, size: size)
    }
}

/// The app's orb (its icon art) in a circle; the drawn orb if the art won't load.
struct JarvisOrbArt: View {
    var size: CGFloat

    var body: some View {
        if let art = jarvisOrbUIImage {
            Image(uiImage: art)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        } else {
            JarvisLiveOrb(size: size)
        }
    }
}

/// A round glass button: a light frosted fill with a bright top edge, white glyph.
struct JarvisGlassCircle<Glyph: View>: View {
    var size: CGFloat
    @ViewBuilder var glyph: Glyph

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background(
                Circle().fill(.white.opacity(0.16))
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)))
    }
}

/// The stop that ends the talk — mic off, reply stopped (Voice Memos' rounded square).
struct JarvisStopButton: View {
    var size: CGFloat = 40

    var body: some View {
        Button(intent: StopJarvisVoiceIntent()) {
            JarvisGlassCircle(size: size) {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

/// The stop during a talk; at rest a mic that starts one right there (the Action
/// button's talk).
struct JarvisVoiceControls: View {
    let st: JarvisActivityAttributes.ContentState
    var size: CGFloat = 40

    var body: some View {
        if jcVoiceActive(st) {
            JarvisStopButton(size: size)
        } else if #available(iOS 18.0, *) {
            Button(intent: TalkToJarvisHereIntent()) {
                JarvisGlassCircle(size: size) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Talk to Jarvis")
        }
    }
}

/// How long the state has run, counting up ("0:04"). The system ticks it, so it
/// moves with no updates. Its box fits "59:59", the widest it reads.
struct JarvisElapsed: View {
    let since: Date
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    var color: Color = .white.opacity(0.5)

    var body: some View {
        Text(timerInterval: since...since.addingTimeInterval(3599), countsDown: false)
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// "Listening 0:04" — the state in the accent and its running time in grey; at
/// rest "Jarvis", offline "Offline".
struct JarvisVoiceStateLine: View {
    let st: JarvisActivityAttributes.ContentState
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            Text(st.connected ? jcVoiceTitle(st.state) : "Offline")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(jcVoiceTint(st))
                .lineLimit(1)
            if jcVoiceActive(st) {
                JarvisElapsed(since: jcVoiceSince(st), size: size)
                    // Snug: the box is sized for "59:59", and a short time sits at
                    // its leading edge.
                    .frame(width: size * 2.5, alignment: .leading)
            }
        }
        .fixedSize()
    }
}

/// What Jarvis is doing while it thinks ("Checking your calendar"), in a small inset
/// capsule with an accent arc.
struct JarvisDoingChip: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(JcAccent.color.opacity(0.25), lineWidth: size * 0.16)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(JcAccent.color, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size * 0.9, height: size * 0.9)
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: size * 2.2)
        .background(Capsule().fill(Color(white: 0.11)))
    }
}

/// The exchange, centred as Siri does it: his words while he talks; his question
/// grey with what Jarvis is doing while it thinks; once Jarvis answers, his
/// question small over the answer.
struct JarvisExchange: View {
    let st: JarvisActivityAttributes.ContentState
    var mainSize: CGFloat = 18
    var mainLines = 2

    var body: some View {
        let said = st.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = st.activity.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 6) {
            switch st.state {
            case "listening":
                if !said.isEmpty { main(said) }
            case "thinking":
                if !said.isEmpty { main(said, dim: true) }
                if !out.isEmpty { JarvisDoingChip(text: out, size: mainSize - 4).padding(.top, 2) }
            case "error":
                if !out.isEmpty { main(out, dim: true) }
            default:
                // Speaking, or the answer left on the card at rest.
                if !out.isEmpty {
                    if !said.isEmpty {
                        Text(said)
                            .font(.system(size: mainSize - 3, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    main(out)
                } else if !said.isEmpty {
                    main(said, dim: true)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func main(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .font(.system(size: mainSize, weight: .semibold))
            .foregroundStyle(.white.opacity(dim ? 0.5 : 0.96))
            .lineLimit(mainLines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The compact island's trailing side: the running timer in the accent while a talk
/// is on (it ticks by itself), a warning for an error, a mic at rest.
struct JarvisCompactTrailing: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        if jcVoiceActive(st) {
            JarvisElapsed(since: jcVoiceSince(st), size: 15, weight: .semibold, color: JcAccent.color)
                .frame(width: 38, alignment: .leading)
        } else if st.connected && st.state == "error" {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(jcStateColor("error"))
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// The Lock Screen / banner card: orb, "Jarvis · Listening 0:04" and the stop across
/// the top, the exchange centred under them.
struct JarvisVoiceLockScreen: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack {
                    JarvisOrbBadge(st: st, size: 50)
                    Spacer(minLength: 8)
                    JarvisVoiceControls(st: st, size: 36)
                }
                HStack(spacing: 5) {
                    if st.connected && st.state != "idle" {
                        Text("Jarvis ·")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    JarvisVoiceStateLine(st: st)
                }
            }
            if jcVoiceHasWords(st) {
                JarvisExchange(st: st, mainSize: 17, mainLines: 3)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, jcVoiceHasWords(st) ? 16 : 10)
    }
}
