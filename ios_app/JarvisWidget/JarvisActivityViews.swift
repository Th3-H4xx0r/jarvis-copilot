import WidgetKit
import SwiftUI
import ActivityKit

@available(iOS 16.2, *)
func jcStateColor(_ s: String) -> Color {
    switch s {
    case "listening": return Color(red: 0.18, green: 0.72, blue: 1.0)  // cyan
    case "thinking":  return Color(red: 0.54, green: 0.49, blue: 1.0)  // violet
    case "speaking":  return Color(red: 1.0,  green: 0.44, blue: 0.85) // pink
    case "error":     return Color(red: 1.0,  green: 0.42, blue: 0.49) // red
    default:          return Color(red: 0.44, green: 0.69, blue: 1.0)  // idle blue
    }
}

@available(iOS 16.2, *)
func jcStateLabel(_ s: String) -> String {
    switch s {
    case "listening": return "Listening"
    case "thinking":  return "Thinking"
    case "speaking":  return "Speaking"
    case "error":     return "Error"
    default:          return "Idle"
    }
}

/// The JARVIS orb: the real app-icon orb (circle-clipped) wrapped in a breathing
/// glow halo tinted by the voice state. The halo pulses on iOS 17+ — symbol
/// effects are the reliable way to get continuous motion inside a Live Activity.
@available(iOS 16.2, *)
struct JarvisOrb: View {
    let state: String
    var size: CGFloat = 44
    var body: some View {
        let c = jcStateColor(state)
        ZStack {
            halo(c)
            orbPicture(c)
                .frame(width: size * 0.84, height: size * 0.84)
                .clipShape(Circle())
                .overlay(Circle().stroke(c.opacity(0.55), lineWidth: max(1, size * 0.03)))
        }
        .frame(width: size, height: size)
        .shadow(color: c.opacity(0.6), radius: size * 0.16)
    }

    @ViewBuilder private func orbPicture(_ c: Color) -> some View {
        if let ui = jarvisOrbUIImage {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            Circle().fill(RadialGradient(colors: [c, c.opacity(0.3)],
                center: .center, startRadius: 0, endRadius: size * 0.5))
        }
    }

    @ViewBuilder private func halo(_ c: Color) -> some View {
        let g = Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(c.opacity(0.6))
            .blur(radius: size * 0.16)
        // Only animate the halo while something is happening — a continuously
        // pulsing widget surface draws power the entire time the activity shows.
        if #available(iOS 17.0, *), state != "idle" {
            g.symbolEffect(.pulse, options: .repeating)
        } else {
            g
        }
    }
}

/// Devices strip: a CENTERED row of icons, one per ONLINE connected device
/// (laptop / phone / desktop / watch / …), each lit with a green glow. No count.
@available(iOS 16.2, *)
struct JarvisDevices: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        // Always show at least this phone, even before the device list loads.
        let kinds = st.devices.isEmpty ? ["phone"] : st.devices
        HStack(spacing: 16) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                Image(systemName: jcDeviceSymbol(kind))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: Color.green.opacity(0.6), radius: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Maps a normalized device kind (set in voice_controller's `_deviceIconKind`,
/// plus "watch" folded in natively) to an SF Symbol.
func jcDeviceSymbol(_ kind: String) -> String {
    switch kind {
    case "laptop": return "laptopcomputer"
    case "phone": return "iphone"
    case "desktop": return "desktopcomputer"
    case "watch": return "applewatch"
    case "tablet": return "ipad"
    case "web": return "globe"
    default: return "display"
    }
}

/// Small state pill, e.g. a cyan `LISTENING`.
@available(iOS 16.2, *)
func jcStatePill(_ state: String) -> some View {
    let c = jcStateColor(state)
    return Text(jcStateLabel(state).uppercased())
        .font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(c)
        .padding(.vertical, 5).padding(.horizontal, 11)
        .background(Capsule().fill(c.opacity(0.2)))
        .overlay(Capsule().stroke(c.opacity(0.45), lineWidth: 1))
}

/// Conversation panel: `YOU` / `JARVIS` rows in a state-tinted glass card.
@available(iOS 16.2, *)
struct JarvisConvo: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        let c = jcStateColor(st.state)
        VStack(alignment: .leading, spacing: 6) {
            if !st.transcript.isEmpty {
                row("YOU", .white.opacity(0.4), st.transcript, .white.opacity(0.95), 2)
            }
            if !st.activity.isEmpty {
                row("JARVIS", c.opacity(0.95), st.activity, .white.opacity(0.78), 2)
            }
            if st.transcript.isEmpty && st.activity.isEmpty {
                Text("Tap to talk")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(c.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.opacity(0.24), lineWidth: 1))
    }

    private func row(_ label: String, _ lc: Color, _ text: String,
                     _ tc: Color, _ lines: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.7)
                .foregroundStyle(lc).frame(width: 44, alignment: .leading).padding(.top, 2)
            Text(text).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tc).lineLimit(lines)
        }
    }
}

// ── Coding mode (Scheme 4) ────────────────────────────────────────────────
// Shown when voice is idle and there are live Claude Code sessions. Colors:
// working = green, waiting = purple (the attention state), idle = grey; the two
// usage rings are 5-hour = red (inner) and weekly = blue (outer).

func jcCodingColor(_ s: String) -> Color {
    switch s {
    case "working": return Color(red: 0.20, green: 0.83, blue: 0.60)  // green
    case "waiting": return Color(red: 0.75, green: 0.52, blue: 0.99)  // purple
    case "dim":     return Color(red: 0.40, green: 0.42, blue: 0.45)  // muted (forgotten)
    default:        return Color(red: 0.51, green: 0.55, blue: 0.59)  // grey (idle)
    }
}

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
let jcUsage5Color = Color(red: 0.98, green: 0.44, blue: 0.52)    // red
let jcUsageWeekColor = Color(red: 0.22, green: 0.74, blue: 0.97) // blue

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
@available(iOS 16.2, *)
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
@available(iOS 16.2, *)
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

/// Header: orb logo + "Claude Code" + "N sessions · M waiting" (+ usage on the
/// right when `showUsage`).
@available(iOS 16.2, *)
struct JCHeader: View {
    let st: JarvisActivityAttributes.ContentState
    var orbSize: CGFloat = 30
    var showUsage: Bool = true
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
            if showUsage {
                Spacer(minLength: 6)
                JCUsageBlock(st: st)
            }
        }
    }
}

/// Segmented bar — one slot per project, equal-width. A project with 2+ live
/// sessions splits its slot into per-session sub-cells (a small inner gap, the
/// "break") colored per sub-state; a single-session slot is one solid capsule.
@available(iOS 16.2, *)
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
@available(iOS 16.2, *)
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
@available(iOS 16.2, *)
struct JarvisCodingBody: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        let sessions = jcDecodeSessions(st.sessions)
        VStack(alignment: .leading, spacing: 11) {
            JCHeader(st: st)
            JCSegBar(sessions: sessions)
            JCLegend(sessions: sessions, total: st.entryTotal)
        }
    }
}

/// Indeterminate circular spinner for the collapsed Dynamic Island's leading
/// slot — a `ProgressView`, which (unlike SF-Symbol effects) actually animates
/// inside a Live Activity. Tinted to the spotlight session's state color.
@available(iOS 16.2, *)
struct JCCompactSpinner: View {
    let color: Color
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(color)
    }
}

/// Compact fleet bar for the collapsed island's trailing slot — one small
/// segment per spotlight session, colored by its state (green working / purple
/// waiting / grey idle). The whole fleet at a glance.
@available(iOS 16.2, *)
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
