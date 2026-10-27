import WidgetKit
import SwiftUI
import ActivityKit

func jcStateLabel(_ s: String) -> String {
    switch s {
    case "listening": return "Listening"
    case "thinking":  return "Thinking"
    case "speaking":  return "Speaking"
    case "error":     return "Error"
    default:          return "Idle"
    }
}

/// The JARVIS orb everywhere in the Live Activities: the Voice page's liquid-glass orb,
/// animated with symbol effects (`JarvisLiveOrb`), its glow tinted by the voice state.
struct JarvisOrb: View {
    let state: String
    var size: CGFloat = 44
    var body: some View {
        JarvisLiveOrb(size: size, glow: jcStateColor(state))
    }
}

// ── Coding mode (Scheme 4) ────────────────────────────────────────────────
// Shown when voice is idle and there are live Claude Code sessions. Colors:
// working = green, waiting = amber (the attention state), idle = grey; the two
// usage rings are 5-hour = red (inner) and weekly = blue (outer).

/// Color for a per-session sub-state shorthand (w/p/i/d) in the segmented bar.
func jcSubColor(_ s: String) -> Color {
    switch s {
    case "w": return jcCodingColor("working")
    case "p": return jcCodingColor("waiting")
    case "d": return jcCodingColor("dim")
    default:  return jcCodingColor("idle")
    }
}

/// A forgotten (detached+idle) entry is de-emphasized: muted color + dimmed.
func jcEntryOpacity(_ state: String) -> Double { state == "dim" ? 0.5 : 1.0 }
func jcCodingStateLabel(_ s: String) -> String {
    switch s {
    case "working": return "working"
    case "waiting": return "waiting"
    default:        return "idle"
    }
}

/// One decoded session row: "name\u{1F}state[\u{1F}subs]" → (name, state, subs).
/// `subStates` is the per-session shorthand list (w/p/i) for a project with 2+
/// live sessions; empty for a single-session row (rendered as one solid segment).
struct JCSession {
    let name: String
    let state: String
    let subStates: [String]
}

func jcDecodeSessions(_ raw: [String]) -> [JCSession] {
    raw.map { s in
        let parts = s.components(separatedBy: "\u{1F}")
        let subs = parts.count > 2
            ? parts[2].split(separator: ",").map(String.init)
            : []
        return JCSession(name: parts.first ?? s,
                         state: parts.count > 1 ? parts[1] : "working",
                         subStates: subs)
    }
}

/// The spotlight session (the coordinator sorts so the most important — a
/// waiting one — is first). Returns nil when there are no sessions.
func jcSpotlight(_ raw: [String]) -> JCSession? { jcDecodeSessions(raw).first }

/// Concentric dual-ring usage gauge: weekly (outer, blue) + 5-hour (inner, red).
struct JCUsageRings: View {
    let pct5: Int
    let pctWeek: Int
    var body: some View {
        ZStack {
            track(44); fill(44, pctWeek, jcUsageWeekColor)
            track(28); fill(28, pct5, jcUsage5Color)
        }
        .frame(width: 46, height: 46)
    }
    private func track(_ d: CGFloat) -> some View {
        Circle().stroke(Color.white.opacity(0.14), lineWidth: 4).frame(width: d, height: d)
    }
    private func fill(_ d: CGFloat, _ pct: Int, _ c: Color) -> some View {
        Circle()
            .trim(from: 0, to: CGFloat(max(0, min(100, pct))) / 100.0)
            .stroke(c, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: d, height: d)
    }
}

/// The usage block: two color-matched % labels beside the dual ring.
struct JCUsageBlock: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .trailing, spacing: 3) {
                label("5h", st.usage5, jcUsage5Color)
                label("wk", st.usageWeek, jcUsageWeekColor)
            }
            JCUsageRings(pct5: st.usage5, pctWeek: st.usageWeek)
        }
    }
    private func label(_ k: String, _ pct: Int, _ c: Color) -> Text {
        Text("\(k) ").font(.system(size: 10, weight: .bold)).foregroundColor(c)
            + Text(pct >= 0 ? "\(pct)%" : "—").font(.system(size: 10, weight: .heavy)).foregroundColor(c)
    }
}

/// Header: orb logo + "Claude Code" + "N sessions · M waiting" + usage on the
/// right.
struct JCHeader: View {
    let st: JarvisActivityAttributes.ContentState
    var orbSize: CGFloat = 30
    var body: some View {
        HStack(spacing: 11) {
            JarvisOrb(state: "idle", size: orbSize)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                (Text("\(st.sessionTotal) sessions").foregroundColor(.white.opacity(0.55))
                 + Text(st.waitingCount > 0 ? " · \(st.waitingCount) waiting" : "")
                    .foregroundColor(jcCodingColor("waiting")))
                    .font(.system(size: 11, weight: .semibold))
            }
            Spacer(minLength: 6)
            JCUsageBlock(st: st)
        }
    }
}

/// Segmented bar — one slot per project, equal-width. A project with 2+ live
/// sessions splits its slot into per-session sub-cells (a small inner gap, the
/// "break") colored per sub-state; a single-session slot is one solid capsule.
struct JCSegBar: View {
    let sessions: [JCSession]
    var body: some View {
        HStack(spacing: 2) {
            if sessions.isEmpty {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12)).frame(height: 8)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                    if s.subStates.count > 1 {
                        HStack(spacing: 1.5) {
                            ForEach(Array(s.subStates.enumerated()), id: \.offset) { _, sub in
                                RoundedRectangle(cornerRadius: 2).fill(jcSubColor(sub)).frame(height: 8)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(jcCodingColor(s.state)).frame(height: 8)
                    }
                }
            }
        }
    }
}

/// Two-column legend of up to 4 sessions, with a "+N more" overflow.
struct JCLegend: View {
    let sessions: [JCSession]
    let total: Int
    var body: some View {
        let pairs = stride(from: 0, to: sessions.count, by: 2).map {
            Array(sessions[$0..<min($0 + 2, sessions.count)])
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 14) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, s in item(s) }
                    if pair.count == 1 { Spacer(minLength: 0) }
                }
            }
            if total > sessions.count {
                Text("+\(total - sessions.count) more")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
    private func item(_ s: JCSession) -> some View {
        HStack(spacing: 7) {
            Circle().fill(jcCodingColor(s.state)).frame(width: 7, height: 7)
            Text(s.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
            Text(jcCodingStateLabel(s.state)).font(.system(size: 9.5))
                .foregroundColor(jcCodingColor(s.state))
        }
        .frame(maxWidth: .infinity)
        // A forgotten (detached+idle) session is de-emphasized, not hidden.
        .opacity(jcEntryOpacity(s.state))
    }
}

/// The full coding view: header + segmented bar + legend (lock screen + the
/// expanded Dynamic Island share it).
struct JarvisCodingBody: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        let sessions = jcDecodeSessions(st.sessions)
        VStack(alignment: .leading, spacing: 11) {
            JCHeader(st: st)
            if !st.leadAgent.isEmpty {
                JCLeadRow(st: st)
            } else {
                JCSegBar(sessions: sessions)
            }
            JCLegend(sessions: sessions, total: st.entryTotal)
        }
    }
}

/// The most urgent agent session: what it is doing, and — when it waits for an
/// approval — Deny / Allow right here (no unlock needed).
struct JCLeadRow: View {
    let st: JarvisActivityAttributes.ContentState

    private var color: Color {
        switch st.leadState {
        case "approval", "question": return jcCodingColor("waiting")
        case "working", "thinking": return jcCodingColor("working")
        case "error": return .red
        default: return jcCodingColor("idle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(st.leadAgent) · \(st.leadProject)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if st.leadSince > 0 && (st.leadState == "working" || st.leadState == "thinking") {
                    Text(Date(timeIntervalSince1970: st.leadSince), style: .timer)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 52, alignment: .trailing)
                }
            }
            if !st.leadStep.isEmpty {
                Text(st.leadStep)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            if st.leadKind == "approval" && !st.leadFingerprint.isEmpty {
                HStack(spacing: 8) {
                    // The app's liquid-glass buttons, one accent (AgentGlassButtonLabel).
                    Button(intent: AgentDenyIntent(fingerprint: st.leadFingerprint)) {
                        AgentGlassButtonLabel(text: "Deny", height: 34)
                    }
                    .buttonStyle(.plain)
                    Button(intent: AgentAllowIntent(fingerprint: st.leadFingerprint)) {
                        AgentGlassButtonLabel(text: "Allow", tint: JcAccent.color, height: 34)
                    }
                    .buttonStyle(.plain)
                }
            } else if st.leadKind == "question" {
                Text("Tap to answer in Jarvis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(jcCodingColor("waiting"))
            }
        }
    }
}

/// The collapsed Dynamic Island's "busy" mark, tinted to the spotlight session's
/// state color. A still arc at a fixed size: the indeterminate `ProgressView`
/// this used to be left the whole island a full-width EMPTY black bar on iOS 27
/// devices (the Lock Screen, which has none, kept rendering). See
/// `AgentBusyRing` in Copilot/Shared/AgentActivityViews.swift.
struct JCCompactSpinner: View {
    let color: Color
    var body: some View {
        AgentBusyRing(color: color, size: 16)
    }
}

/// Compact fleet bar for the collapsed island's trailing slot — one small
/// segment per spotlight session, colored by its state (green working / amber
/// waiting / grey idle). The whole fleet at a glance.
struct JCCompactFleetBar: View {
    let sessions: [JCSession]
    var body: some View {
        HStack(spacing: 2) {
            if sessions.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.15)).frame(width: 40, height: 7)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(jcCodingColor(s.state)).frame(width: 13, height: 7)
                }
            }
        }
    }
}

// ── CarPlay card (the activity's `.small` family) ─────────────────────────────

/// Picks the CarPlay / Smart Stack card for the `.small` family, the full
/// Lock Screen layout otherwise.
struct JarvisFamilyLockScreen: View {
    @Environment(\.activityFamily) private var family
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        if family == .small {
            JarvisSmallActivity(st: st)
        } else {
            JarvisLockScreen(st: st)
        }
    }
}

/// The CarPlay Dashboard card: the orb and what's happening, then his words while he
/// talks and Jarvis's reply after — two short lines at most.
struct JarvisSmallActivity: View {
    let st: JarvisActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            JarvisOrb(state: st.mode == "voice" ? st.state : "idle", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(st.mode == "voice" && st.state != "idle" ? jcStateColor(st.state) : .white)
                    .lineLimit(1)
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private var title: String {
        switch st.mode {
        case "coding": return "Claude Code"
        case "custom": return "JARVIS"
        default: return CarCardText.title(state: st.state)
        }
    }

    private var line: String {
        switch st.mode {
        case "coding":
            return "\(st.sessionTotal) sessions" + (st.waitingCount > 0 ? " · \(st.waitingCount) waiting" : "")
        case "custom": return ""
        default: return CarCardText.line(state: st.state, transcript: st.transcript, activity: st.activity)
        }
    }
}
