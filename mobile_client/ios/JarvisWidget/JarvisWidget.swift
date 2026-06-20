import WidgetKit
import SwiftUI
import AppIntents
import UIKit

/// iOS Lock Screen + Home Screen widget that quick-launches JarvisCopilot
/// straight into the Voice screen. Tapping opens `jarviscopilot://voice`, which
/// AppDelegate.handleIncomingURL routes to the same path as the Siri voice
/// intent (opens the Voice tab and starts a realtime turn).
///
/// Add to your Lock Screen: long-press the Lock Screen → Customize → the area
/// under the clock → add the "JARVIS Voice" circular widget.
struct JarvisWidgetEntry: TimelineEntry { let date: Date }

struct JarvisWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisWidgetEntry { JarvisWidgetEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (JarvisWidgetEntry) -> Void) {
        completion(JarvisWidgetEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisWidgetEntry>) -> Void) {
        completion(Timeline(entries: [JarvisWidgetEntry(date: Date())], policy: .never))
    }
}

struct JarvisWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: JarvisWidgetProvider.Entry

    var body: some View {
        switch family {
        case .accessoryCircular:
            // Lock Screen: a 1×1 circular mic. accessoryWidgetBackground gives
            // the standard translucent ring; widgetAccentable tints it.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "atom")
                    .font(.system(size: 22, weight: .semibold))
            }
            .widgetAccentable()
            .jcContainerBackground(Color.clear)
            .widgetURL(URL(string: "jarviscopilot://voice"))
        default:
            // Home Screen systemSmall: gradient tile with the mic, on-brand.
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.27, green: 0.88, blue: 0.88),
                             Color(red: 0.54, green: 0.49, blue: 1.0),
                             Color(red: 1.0, green: 0.44, blue: 0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: "atom")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Talk to JARVIS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .jcContainerBackground(Color.black)
            .widgetURL(URL(string: "jarviscopilot://voice"))
        }
    }
}

extension View {
    /// `containerBackground(for: .widget)` is iOS 17+. On 16 it's a no-op (the
    /// widget still renders), so gate it on availability to keep the iOS-16
    /// deployment target building.
    @ViewBuilder
    func jcContainerBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(style, for: .widget)
        } else {
            self
        }
    }
}

struct JarvisWidget: Widget {
    let kind = "JarvisWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarvisWidgetProvider()) { entry in
            JarvisWidgetView(entry: entry)
        }
        .configurationDisplayName("JARVIS Voice")
        .description("Quick-launch JARVIS into voice.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

// ── Control Center button (iOS 18+) ──────────────────────────────────────────
//
// A Control Center control that quick-launches JARVIS into the Voice screen and
// starts listening. Tapping it runs `OpenJarvisVoiceIntent` (in the shared
// VoiceLaunchIntent.swift — a member of both this extension and the app):
// because it sets `openAppWhenRun`, iOS runs it IN THE APP, where it sets the
// pending-voice flag + posts the start notification — the same proven path Siri
// uses. (A custom URL scheme via OpenURLIntent proved unreliable from a Control.)
//
// Add it from: Settings → Control Center (or edit Control Center → "+") → add
// "Talk to JARVIS".

@available(iOS 18.0, *)
struct JarvisVoiceControl: ControlWidget {
    static let kind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget.VoiceControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenJarvisVoiceIntent()) {
                Label("Talk to JARVIS", systemImage: "atom")
            }
        }
        .displayName("Talk to JARVIS")
        .description("Quick-launch JARVIS into voice and start listening.")
    }
}

// ── Dynamic Island + Lock Screen Live Activity (iOS 16.2+) ───────────────────
//
// JARVIS's live voice status: a state-styled glowing orb, the current state, a
// one-line activity (your phrase / reply snippet / "Searching the web…"), and a
// Connected/Offline footer. Tapping anywhere opens the Voice screen. Persists
// (resting at Idle) after a session until dismissed. App-driven via
// LiveActivityManager (AppDelegate). Uses JarvisActivityAttributes (shared).

@available(iOS 16.2, *)
private func jcStateColor(_ s: String) -> Color {
    switch s {
    case "listening": return Color(red: 0.18, green: 0.72, blue: 1.0)  // cyan
    case "thinking":  return Color(red: 0.54, green: 0.49, blue: 1.0)  // violet
    case "speaking":  return Color(red: 1.0,  green: 0.44, blue: 0.85) // pink
    case "error":     return Color(red: 1.0,  green: 0.42, blue: 0.49) // red
    default:          return Color(red: 0.44, green: 0.69, blue: 1.0)  // idle blue
    }
}

@available(iOS 16.2, *)
private func jcStateLabel(_ s: String) -> String {
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

private func jcCodingColor(_ s: String) -> Color {
    switch s {
    case "working": return Color(red: 0.20, green: 0.83, blue: 0.60)  // green
    case "waiting": return Color(red: 0.75, green: 0.52, blue: 0.99)  // purple
    case "dim":     return Color(red: 0.40, green: 0.42, blue: 0.45)  // muted (forgotten)
    default:        return Color(red: 0.51, green: 0.55, blue: 0.59)  // grey (idle)
    }
}

/// Color for a per-session sub-state shorthand (w/p/i/d) in the segmented bar.
private func jcSubColor(_ s: String) -> Color {
    switch s {
    case "w": return jcCodingColor("working")
    case "p": return jcCodingColor("waiting")
    case "d": return jcCodingColor("dim")
    default:  return jcCodingColor("idle")
    }
}

/// A forgotten (detached+idle) entry is de-emphasized: muted color + dimmed.
private func jcEntryOpacity(_ state: String) -> Double { state == "dim" ? 0.5 : 1.0 }
private let jcUsage5Color = Color(red: 0.98, green: 0.44, blue: 0.52)    // red
private let jcUsageWeekColor = Color(red: 0.22, green: 0.74, blue: 0.97) // blue

private func jcCodingStateLabel(_ s: String) -> String {
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

// ══════════════════════════════════════════════════════════════════════════
// MARK: - Dynamic Island Designs — data-driven renderer (JCDesignView)
// ══════════════════════════════════════════════════════════════════════════
//
// When ContentState.mode == "custom", the activity renders a declarative layout
// tree instead of the hard-coded voice/coding views. The tree is NOT in the
// ContentState (4KB cap) — it's cached on-device by the Runner app under the
// shared App Group `island/design-<id>.json` and read here (a SEPARATE process).
// The ContentState carries only {designId, designVersion, data}; `data` is a
// JSON object string of the live values bound into the tree via ValueRefs.
//
// Animation inside a Live Activity is limited to Text(timerInterval:),
// ProgressView, content-update transitions, and SF-Symbol .symbolEffect (iOS 17+
// only) — everything else is static between pushes. The renderer never crashes
// and never goes blank: a missing/corrupt design falls back to the app name +
// data.title; unknown node types are skipped; recursion/count are clamped.

// ── App Group container access ───────────────────────────────────────────────
enum JCDesignCache {
    /// MUST match Runner.entitlements + JarvisWidget.entitlements +
    /// IslandDesignCache.appGroupId (AppDelegate.swift).
    static let appGroupId = "group.com.jarviscopilot.jarviscopilotMobileAndIOS"

    /// Read + decode `island/design-<id>.json`. Returns nil if missing/corrupt.
    static func load(_ designId: String) -> JCDesign? {
        guard !designId.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let safe = designId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let file = container
            .appendingPathComponent("island", isDirectory: true)
            .appendingPathComponent("design-\(safe).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(JCDesign.self, from: data)
    }
}

// ── Decodable layout model ───────────────────────────────────────────────────

/// Top-level cached design object.
struct JCDesign: Decodable {
    var schema: Int = 1
    var id: String = ""
    var version: Int = 0
    var name: String = ""
    var icon: String = ""
    var tint: String = ""
    var presentations: JCPresentations = JCPresentations()

    enum CodingKeys: String, CodingKey {
        case schema, id, version, name, icon, tint, presentations
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        icon = (try? c.decode(String.self, forKey: .icon)) ?? ""
        tint = (try? c.decode(String.self, forKey: .tint)) ?? ""
        presentations = (try? c.decode(JCPresentations.self, forKey: .presentations))
            ?? JCPresentations()
    }
    init() {}
}

struct JCPresentations: Decodable {
    var expanded: JCNode?
    var lockScreen: JCNode?
    var compactLeading: JCNode?
    var compactTrailing: JCNode?
    var minimal: JCNode?

    enum CodingKeys: String, CodingKey {
        case expanded, lockScreen, compactLeading, compactTrailing, minimal
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expanded = try? c.decode(JCNode.self, forKey: .expanded)
        lockScreen = try? c.decode(JCNode.self, forKey: .lockScreen)
        compactLeading = try? c.decode(JCNode.self, forKey: .compactLeading)
        compactTrailing = try? c.decode(JCNode.self, forKey: .compactTrailing)
        minimal = try? c.decode(JCNode.self, forKey: .minimal)
    }
    init() {}
}

/// A node in the layout tree: `{type, ...props, style?, when?}`. The `type` is a
/// dynamic string (forward-compat: unknown types render as a placeholder/omit),
/// so props are decoded leniently into a loosely-typed bag.
struct JCNode: Decodable {
    var type: String = ""
    var style: JCStyle?
    var when: JCJSON?          // condition; nil = always shown
    var props: [String: JCJSON] = [:]

    /// Convenience prop accessors (all optional / tolerant of missing keys).
    func ref(_ key: String) -> JCValueRef? { props[key].map(JCValueRef.init) }
    func node(_ key: String) -> JCNode? { props[key]?.asNode() }
    func nodes(_ key: String) -> [JCNode] { props[key]?.asNodeArray() ?? [] }
    func string(_ key: String) -> String? { props[key]?.asString }
    func int(_ key: String) -> Int? { props[key]?.asInt }
    func double(_ key: String) -> Double? { props[key]?.asDouble }
    func bool(_ key: String) -> Bool? { props[key]?.asBool }

    private struct DynKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: DynKey.self) else {
            return  // not an object → empty placeholder node
        }
        for key in c.allKeys {
            switch key.stringValue {
            case "type":
                type = (try? c.decode(String.self, forKey: key)) ?? ""
            case "style":
                style = try? c.decode(JCStyle.self, forKey: key)
            case "when":
                when = try? c.decode(JCJSON.self, forKey: key)
            default:
                if let v = try? c.decode(JCJSON.self, forKey: key) {
                    props[key.stringValue] = v
                }
            }
        }
    }
    init(type: String) { self.type = type }
}

/// Per-node visual overrides — all optional.
struct JCStyle: Decodable {
    var color: String?
    var font: String?
    var size: Double?
    var weight: String?
    var opacity: Double?
    var padding: Double?
    var align: String?
    var tint: String?
    var width: Double?
    var height: Double?
    var minHeight: Double?  // force a container to fill toward the ~144pt cap

    enum CodingKeys: String, CodingKey {
        case color, font, size, weight, opacity, padding, align, tint, width,
             height, minHeight
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try? c.decode(String.self, forKey: .color)
        font = try? c.decode(String.self, forKey: .font)
        size = try? c.decode(Double.self, forKey: .size)
        weight = try? c.decode(String.self, forKey: .weight)
        opacity = try? c.decode(Double.self, forKey: .opacity)
        padding = try? c.decode(Double.self, forKey: .padding)
        align = try? c.decode(String.self, forKey: .align)
        tint = try? c.decode(String.self, forKey: .tint)
        width = try? c.decode(Double.self, forKey: .width)
        height = try? c.decode(Double.self, forKey: .height)
        minHeight = try? c.decode(Double.self, forKey: .minHeight)
    }
}

/// A tolerant JSON value (used for props, ValueRefs, conditions, list rows).
indirect enum JCJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JCJSON])
    case object([String: JCJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JCJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JCJSON].self) { self = .object(o); return }
        self = .null
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JCJSON.numberString(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var asInt: Int? { asDouble.map { Int($0) } }
    var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }
    var asObject: [String: JCJSON]? { if case .object(let o) = self { return o }; return nil }
    var asArray: [JCJSON]? { if case .array(let a) = self { return a }; return nil }

    func asNode() -> JCNode? {
        guard let o = asObject else { return nil }
        return JCJSON.decodeNode(from: o)
    }
    func asNodeArray() -> [JCNode]? {
        guard let a = asArray else { return nil }
        return a.compactMap { $0.asNode() }
    }

    /// Re-encode an object value back into a JCNode (props were captured as JCJSON
    /// so nested child nodes need re-materializing through the JCNode decoder).
    static func decodeNode(from obj: [String: JCJSON]) -> JCNode? {
        guard let data = try? JSONEncoder().encode(JCJSONBox(obj)) else { return nil }
        return try? JSONDecoder().decode(JCNode.self, from: data)
    }

    static func numberString(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}

/// Encodable wrapper so a captured JCJSON object can be re-serialized (to feed
/// the JCNode decoder for nested children). Only the object case is needed.
private struct JCJSONBox: Encodable {
    let obj: [String: JCJSON]
    init(_ obj: [String: JCJSON]) { self.obj = obj }
    struct DynKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        for (k, v) in obj {
            try JCJSON.encodeValue(v, into: &c, key: DynKey(stringValue: k)!)
        }
    }
}

extension JCJSON {
    fileprivate static func encodeValue(
        _ v: JCJSON, into c: inout KeyedEncodingContainer<JCJSONBox.DynKey>,
        key: JCJSONBox.DynKey
    ) throws {
        switch v {
        case .string(let s): try c.encode(s, forKey: key)
        case .number(let n): try c.encode(n, forKey: key)
        case .bool(let b): try c.encode(b, forKey: key)
        case .null: try c.encodeNil(forKey: key)
        case .array(let a): try c.encode(JCJSONArrayBox(a), forKey: key)
        case .object(let o): try c.encode(JCJSONBox(o), forKey: key)
        }
    }
}

private struct JCJSONArrayBox: Encodable {
    let arr: [JCJSON]
    init(_ arr: [JCJSON]) { self.arr = arr }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in arr {
            switch v {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            case .array(let a): try c.encode(JCJSONArrayBox(a))
            case .object(let o): try c.encode(JCJSONBox(o))
            }
        }
    }
}

// ── ValueRef resolution + binding context ────────────────────────────────────

/// A ValueRef: literal, `{"$":"key"}`, `{"$row":"field"}`, or `{"src":...}` (the
/// last resolves UPSTREAM — the widget treats an unresolved src as missing).
/// Optional transforms: `"fmt":"{}%"` and `"map":{"working":"#34c759",...}`.
struct JCValueRef {
    let raw: JCJSON
    init(_ raw: JCJSON) { self.raw = raw }

    /// Resolve to a display string, or nil when missing/unbound.
    func string(_ ctx: JCBindingContext) -> String? {
        resolve(ctx).flatMap { applyTransforms($0, kind: .string) }
    }
    /// Resolve to a number (0–100 progress, gauge values, etc.), or nil.
    func double(_ ctx: JCBindingContext) -> Double? {
        guard let v = resolve(ctx) else { return nil }
        if case .string = v, let s = applyTransforms(v, kind: .string) { return Double(s) }
        return v.asDouble
    }
    func array(_ ctx: JCBindingContext) -> [JCJSON]? { resolve(ctx)?.asArray }

    /// The raw bound JCJSON (literal or looked-up), before fmt/map.
    func resolve(_ ctx: JCBindingContext) -> JCJSON? {
        switch raw {
        case .object(let o):
            if let key = o["$"]?.asString { return ctx.data[key] }
            if let field = o["$row"]?.asString { return ctx.row?[field] }
            // A source binding resolves to data[key] too — the coordinator (awake)
            // or server (suspended) places the resolved value under the src key.
            // Absent → nil (renders as missing), never a crash.
            if let key = o["src"]?.asString { return ctx.data[key] }
            return raw  // a plain object literal (rare) — pass through
        default:
            return raw  // literal string/number/bool
        }
    }

    private enum Kind { case string }
    private func applyTransforms(_ v: JCJSON, kind: Kind) -> String? {
        var s: String?
        // map: value → mapped string (e.g. state → hex color, or label).
        if case .object(let o) = raw, let mapObj = o["map"]?.asObject,
           let key = v.asString, let mapped = mapObj[key]?.asString {
            s = mapped
        } else {
            s = v.asString
        }
        guard var out = s else { return nil }
        // fmt: "{}" placeholder substitution (e.g. "{}%").
        if case .object(let o) = raw, let fmt = o["fmt"]?.asString {
            out = fmt.replacingOccurrences(of: "{}", with: out)
        }
        return out
    }

    /// Mapped color hex for ValueRefs whose map yields color strings.
    func color(_ ctx: JCBindingContext) -> Color? {
        guard let s = string(ctx) else { return nil }
        return jcParseColor(s)
    }
}

/// Holds the decoded `data` dict + the current `$row` (inside a list template).
struct JCBindingContext {
    let data: [String: JCJSON]
    var row: [String: JCJSON]?

    init(dataJSON: String) {
        if let d = dataJSON.data(using: .utf8),
           let obj = try? JSONDecoder().decode([String: JCJSON].self, from: d) {
            data = obj
        } else {
            data = [:]
        }
        row = nil
    }
    private init(data: [String: JCJSON], row: [String: JCJSON]?) {
        self.data = data; self.row = row
    }
    func withRow(_ row: [String: JCJSON]) -> JCBindingContext {
        JCBindingContext(data: data, row: row)
    }
}

// ── Color + condition helpers ────────────────────────────────────────────────

/// Parse a color: #rrggbb / #rrggbbaa hex, or a small named palette that matches
/// the coding-mode colors. Returns nil for unknown.
func jcParseColor(_ s: String) -> Color? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("#") {
        let hex = String(t.dropFirst())
        guard let val = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((val >> 16) & 0xff) / 255
            g = Double((val >> 8) & 0xff) / 255
            b = Double(val & 0xff) / 255
            a = 1
        case 8:
            r = Double((val >> 24) & 0xff) / 255
            g = Double((val >> 16) & 0xff) / 255
            b = Double((val >> 8) & 0xff) / 255
            a = Double(val & 0xff) / 255
        default:
            return nil
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
    switch t.lowercased() {
    case "white": return .white
    case "black": return .black
    case "clear": return .clear
    case "green": return jcCodingColor("working")
    case "purple", "violet": return jcCodingColor("waiting")
    case "grey", "gray": return jcCodingColor("idle")
    case "red": return jcUsage5Color
    case "blue": return jcUsageWeekColor
    case "cyan": return jcStateColor("listening")
    case "pink": return jcStateColor("speaking")
    default: return nil
    }
}

/// Evaluate a `when` condition expression against the binding context. Unknown /
/// malformed → true (fail-open so a typo doesn't blank the whole design).
func jcEvalCondition(_ expr: JCJSON?, _ ctx: JCBindingContext) -> Bool {
    guard let expr = expr else { return true }
    guard let o = expr.asObject, let op = o["op"]?.asString else { return true }
    func operand(_ key: String) -> JCJSON? {
        guard let v = o[key] else { return nil }
        return JCValueRef(v).resolve(ctx)
    }
    switch op {
    case "and":
        return (o["items"]?.asArray ?? []).allSatisfy { jcEvalCondition($0, ctx) }
    case "or":
        return (o["items"]?.asArray ?? []).contains { jcEvalCondition($0, ctx) }
    case "not":
        return !jcEvalCondition(o["item"], ctx)
    case "exists":
        return operand("a") != nil
    case "eq":
        return (operand("a")?.asString) == (operand("b")?.asString)
    case "ne":
        return (operand("a")?.asString) != (operand("b")?.asString)
    case "gt":
        if let a = operand("a")?.asDouble, let b = operand("b")?.asDouble { return a > b }
        return false
    case "lt":
        if let a = operand("a")?.asDouble, let b = operand("b")?.asDouble { return a < b }
        return false
    case "between":
        if let v = operand("a")?.asDouble,
           let lo = operand("lo")?.asDouble, let hi = operand("hi")?.asDouble {
            return v >= lo && v <= hi
        }
        return false
    default:
        return true
    }
}

// ── The renderer ─────────────────────────────────────────────────────────────

/// Recursive renderer with depth/count safety clamps. Build one per render pass
/// (the count is mutated). Unknown node types render nothing. Never crashes.
@available(iOS 16.2, *)
final class JCDesignRenderer {
    private var count = 0
    // Generous safety clamps (not a layout limit): the expanded island + lock
    // screen size to their content, so a rich design can fill the full available
    // height. These only guard against pathological/cyclic trees.
    private let maxDepth = 12
    private let maxNodes = 160
    let tint: Color

    init(tint: Color) { self.tint = tint }

    func render(_ node: JCNode?, _ ctx: JCBindingContext, depth: Int = 0) -> AnyView {
        guard let node = node, depth <= maxDepth, count < maxNodes else {
            return AnyView(EmptyView())
        }
        // `when` gating — skip a node (and its subtree) when its condition fails.
        if !jcEvalCondition(node.when, ctx) { return AnyView(EmptyView()) }
        count += 1
        let view = body(node, ctx, depth: depth)
        return AnyView(applyStyle(view, node.style, ctx))
    }

    @ViewBuilder
    private func body(_ n: JCNode, _ ctx: JCBindingContext, depth: Int) -> some View {
        switch n.type {
        // ── Containers ──────────────────────────────────────────────────────
        case "hstack":
            HStack(alignment: jcVAlign(n.string("align")), spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "vstack":
            VStack(alignment: jcHAlign(n.string("align")), spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "zstack":
            ZStack {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "grid":
            let cols = max(1, n.int("columns") ?? 2)
            let items = Array(repeating: GridItem(.flexible(), spacing: jcSpacing(n)),
                              count: cols)
            LazyVGrid(columns: items, spacing: jcSpacing(n)) {
                ForEach(jcIndexed(n.nodes("children")), id: \.0) { _, child in
                    self.render(child, ctx, depth: depth + 1)
                }
            }
        case "list":
            renderList(n, ctx, depth: depth)
        case "spacer":
            if let m = n.double("minLength") { Spacer(minLength: CGFloat(m)) } else { Spacer() }
        case "regions":
            // Outside the DI expanded region wiring (lock screen), flatten the
            // regions into a vertical stack so nothing is lost.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["leading", "trailing", "center", "bottom"], id: \.self) { key in
                    self.render(n.node(key), ctx, depth: depth + 1)
                }
            }
        // ── Leaves ──────────────────────────────────────────────────────────
        case "text":
            jcText(n.ref("value")?.string(ctx) ?? "", n, ctx)
                .lineLimit(n.int("lineLimit") ?? 1)
        case "titleSubtitle":
            VStack(alignment: .leading, spacing: 2) {
                jcText(n.ref("title")?.string(ctx) ?? "", n, ctx, size: 14, weight: .bold)
                    .lineLimit(1)
                jcText(n.ref("subtitle")?.string(ctx) ?? "", n, ctx,
                       size: 11, weight: .semibold, opacity: 0.6)
                    .lineLimit(1)
            }
        case "stat":
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                jcText(n.ref("value")?.string(ctx) ?? "—", n, ctx, size: 22, weight: .heavy)
                if let unit = n.ref("unit")?.string(ctx) {
                    jcText(unit, n, ctx, size: 11, weight: .semibold, opacity: 0.6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let cap = n.ref("caption")?.string(ctx) {
                    jcText(cap, n, ctx, size: 9, weight: .medium, opacity: 0.5)
                        .offset(y: 12)
                }
            }
        case "symbol":
            jcSymbol(n, ctx)
        case "symbolValue":
            HStack(spacing: 5) {
                if let name = n.ref("symbol")?.string(ctx) {
                    Image(systemName: name).font(.system(size: n.style?.size.map { CGFloat($0) } ?? 13))
                        .foregroundStyle(n.style?.color.flatMap(jcParseColor) ?? .white)
                }
                jcText(n.ref("value")?.string(ctx) ?? "", n, ctx, size: 13, weight: .semibold)
            }
        case "image":
            jcImage(n, ctx)
        case "dot":
            Circle()
                .fill(n.ref("color")?.color(ctx) ?? tint)
                .frame(width: 8, height: 8)
        case "badge":
            jcBadge(n, ctx)
        case "progress":
            jcProgress(n, ctx)
        case "segbar":
            jcSegbar(n, ctx)
        case "gauge":
            jcGauge(n, ctx)
        case "timer":
            jcTimer(n, ctx)
        case "timeProgress":
            jcTimeProgress(n, ctx)
        case "keyValue":
            jcKeyValue(n, ctx)
        case "sparkline":
            jcSparkline(n, ctx)
        case "iconStrip":
            jcIconStrip(n, ctx)
        case "waveform":
            jcWaveform(n)
        case "divider":
            Divider().overlay(Color.white.opacity(0.18))
        case "accent":
            RoundedRectangle(cornerRadius: 2)
                .fill(n.ref("color")?.color(ctx) ?? tint)
                .frame(width: 3)
        default:
            // Unknown type → render nothing (forward-compat).
            EmptyView()
        }
    }

    // ── List ────────────────────────────────────────────────────────────────
    @ViewBuilder
    private func renderList(_ n: JCNode, _ ctx: JCBindingContext, depth: Int) -> some View {
        let rows = (n.ref("data")?.array(ctx) ?? []).compactMap { $0.asObject }
        let maxRows = max(0, min(n.int("max") ?? rows.count, rows.count))
        if rows.isEmpty {
            render(n.node("empty"), ctx, depth: depth + 1)
        } else if let cols = n.int("columns"), cols > 1 {
            let items = Array(repeating: GridItem(.flexible(), spacing: 6), count: cols)
            LazyVGrid(columns: items, alignment: .leading, spacing: 6) {
                ForEach(0..<maxRows, id: \.self) { i in
                    self.render(n.node("row"), ctx.withRow(rows[i]), depth: depth + 1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<maxRows, id: \.self) { i in
                    self.render(n.node("row"), ctx.withRow(rows[i]), depth: depth + 1)
                }
            }
        }
    }

    // ── Leaf builders ─────────────────────────────────────────────────────────
    private func jcText(_ s: String, _ n: JCNode, _ ctx: JCBindingContext,
                        size: CGFloat = 13, weight: Font.Weight = .medium,
                        opacity: Double = 1) -> some View {
        let sz = n.style?.size.map { CGFloat($0) } ?? size
        let w = n.style?.weight.flatMap(jcWeight) ?? weight
        let col = n.style?.color.flatMap(jcParseColor) ?? .white
        let op = n.style?.opacity ?? opacity
        return Text(s).font(.system(size: sz, weight: w)).foregroundStyle(col.opacity(op))
    }

    @ViewBuilder
    private func jcSymbol(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let name = n.ref("name")?.string(ctx) ?? n.string("name") ?? "questionmark"
        let sz = n.style?.size.map { CGFloat($0) } ?? 16
        let col = n.style?.color.flatMap(jcParseColor) ?? n.style?.tint.flatMap(jcParseColor) ?? .white
        let img = Image(systemName: name).font(.system(size: sz)).foregroundStyle(col)
        if #available(iOS 17.0, *), let effect = n.string("effect") {
            switch effect {
            case "pulse": img.symbolEffect(.pulse, options: .repeating)
            case "bounce": img.symbolEffect(.bounce, options: .repeating)
            case "variableColor": img.symbolEffect(.variableColor, options: .repeating)
            default: img
            }
        } else {
            img
        }
    }

    @ViewBuilder
    private func jcImage(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // No remote/asset loading inside the extension — `source` is treated as an
        // SF Symbol name for safety (placeholder otherwise). The shared orb image
        // is available under the reserved source "orb".
        let source = n.ref("source")?.string(ctx) ?? n.string("source") ?? ""
        let w = n.style?.width.map { CGFloat($0) } ?? 28
        let h = n.style?.height.map { CGFloat($0) } ?? w
        let shape = n.string("shape") ?? "circle"
        let base: AnyView = {
            if source == "orb", let ui = jarvisOrbUIImage {
                return AnyView(Image(uiImage: ui).resizable().scaledToFill())
            } else if !source.isEmpty {
                return AnyView(Image(systemName: source).resizable().scaledToFit()
                    .foregroundStyle(.white))
            }
            return AnyView(Rectangle().fill(Color.white.opacity(0.1)))
        }()
        base
            .frame(width: w, height: h)
            .clipShape(shape == "rounded"
                ? JCAnyShape(RoundedRectangle(cornerRadius: 6))
                : JCAnyShape(Circle()))
    }

    private func jcBadge(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let text = n.ref("text")?.string(ctx) ?? ""
        let c = n.ref("color")?.color(ctx) ?? tint
        return Text(text)
            .font(.system(size: 10, weight: .heavy)).tracking(0.5)
            .foregroundStyle(c)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(Capsule().fill(c.opacity(0.2)))
            .overlay(Capsule().stroke(c.opacity(0.45), lineWidth: 1))
    }

    private func jcProgress(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let v = jcClamp01((n.ref("value")?.double(ctx) ?? 0) / jcScale(n))
        let c = n.ref("tint")?.color(ctx) ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(c).frame(width: geo.size.width * CGFloat(v))
            }
        }
        .frame(height: 8)
    }

    private func jcSegbar(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let segs = (n.ref("segments")?.array(ctx) ?? []).compactMap { $0.asObject }
        return HStack(spacing: 2) {
            if segs.isEmpty {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12)).frame(height: 8)
            } else {
                ForEach(jcIndexed(segs), id: \.0) { _, seg in
                    let weight = max(0.0001, seg["weight"]?.asDouble ?? 1)
                    let c = seg["color"]?.asString.flatMap(jcParseColor) ?? self.tint
                    RoundedRectangle(cornerRadius: 2).fill(c)
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(weight)
                }
            }
        }
    }

    @ViewBuilder
    private func jcGauge(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // style "single" → one ring; "concentric" → nested rings (both built from
        // the `rings:[{value,tint}]` prop, with a single-`value` fallback).
        let rings = gaugeRingsFromProps(n, ctx)
        let label = n.ref("label")?.string(ctx)
        ZStack {
            ForEach(jcIndexed(rings), id: \.0) { i, ring in
                let d: CGFloat = 46 - CGFloat(i) * 16
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 4).frame(width: d, height: d)
                Circle().trim(from: 0, to: CGFloat(jcClamp01(ring.value)))
                    .stroke(ring.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: d, height: d)
            }
            if let label = label {
                Text(label).font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 48, height: 48)
    }

    private struct GaugeRing { let value: Double; let tint: Color }
    private func gaugeRingsFromProps(_ n: JCNode, _ ctx: JCBindingContext) -> [GaugeRing] {
        // rings: [{value, tint}] — value 0..1 (or 0..100 with scale).
        let raw = n.props["rings"]?.asArray ?? []
        let scale = jcScale(n)
        let rings = raw.compactMap { item -> GaugeRing? in
            guard let o = item.asObject else { return nil }
            let val = JCValueRef(o["value"] ?? .null).double(ctx) ?? (o["value"]?.asDouble ?? 0)
            let tintC = o["tint"]?.asString.flatMap(jcParseColor) ?? tint
            return GaugeRing(value: val / scale, tint: tintC)
        }
        if rings.isEmpty {
            // single-style fallback: one ring from `value`.
            let v = (n.ref("value")?.double(ctx) ?? 0) / scale
            return [GaugeRing(value: v, tint: tint)]
        }
        return rings
    }

    @ViewBuilder
    private func jcTimer(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // `to` is an epoch seconds (number) or ISO string we parse to a Date.
        let toRef = n.ref("to")
        if let date = jcParseDate(toRef?.resolve(ctx)) {
            let countdown = (n.string("mode") ?? "countdown") == "countdown"
            let range = countdown ? date...Date.distantFuture : Date.distantPast...date
            Text(timerInterval: range, countsDown: countdown)
                .font(.system(size: n.style?.size.map { CGFloat($0) } ?? 15,
                              weight: n.style?.weight.flatMap(jcWeight) ?? .semibold))
                .foregroundStyle(n.style?.color.flatMap(jcParseColor) ?? .white)
                .monospacedDigit()
        } else {
            Text("--:--").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4)).monospacedDigit()
        }
    }

    @ViewBuilder
    private func jcTimeProgress(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        // A self-filling progress bar from `from`→`to` (epoch/ISO dates). Renders
        // OFFLINE with no code: ProgressView(timerInterval:) advances on its own,
        // so flight progress keeps moving with no network.
        let barTint = n.ref("tint")?.color(ctx)
            ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        if let from = jcParseDate(n.ref("from")?.resolve(ctx)),
           let to = jcParseDate(n.ref("to")?.resolve(ctx)), to > from {
            ProgressView(timerInterval: from...to, countsDown: false)
                .progressViewStyle(.linear)
                .tint(barTint)
                .labelsHidden()
        } else {
            ProgressView(value: 0.0)
                .progressViewStyle(.linear)
                .tint(barTint)
        }
    }

    private func jcKeyValue(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let pairs = (n.props["pairs"]?.asArray ?? []).compactMap { $0.asObject }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(jcIndexed(pairs), id: \.0) { _, p in
                HStack {
                    Text(JCValueRef(p["label"] ?? .null).string(ctx) ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 8)
                    Text(JCValueRef(p["value"] ?? .null).string(ctx) ?? "")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func jcSparkline(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let pts = (n.ref("points")?.array(ctx) ?? []).compactMap { $0.asDouble }
        let c = n.ref("tint")?.color(ctx) ?? n.style?.tint.flatMap(jcParseColor) ?? tint
        let kind = n.string("kind") ?? "line"
        return JCSparklineShape(points: pts, filled: kind == "area")
            .stroke(c, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .background(
                kind == "area"
                    ? AnyView(JCSparklineShape(points: pts, filled: true)
                        .fill(c.opacity(0.18)))
                    : AnyView(EmptyView())
            )
            .frame(height: 22)
    }

    private func jcIconStrip(_ n: JCNode, _ ctx: JCBindingContext) -> some View {
        let items = (n.ref("items")?.array(ctx) ?? []).compactMap { $0.asString }
        let maxN = n.int("max") ?? items.count
        let shown = Array(items.prefix(max(0, maxN)))
        return HStack(spacing: 12) {
            ForEach(jcIndexed(shown), id: \.0) { _, name in
                Image(systemName: name).font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if items.count > shown.count {
                Text("+\(items.count - shown.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func jcWaveform(_ n: JCNode) -> some View {
        // Static bars (a Live Activity can't drive a continuous custom animation);
        // reads as a "voice" affordance.
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(self.tint.opacity(0.8))
                    .frame(width: 3, height: [10.0, 18, 8, 22, 12, 16, 9][i % 7])
            }
        }
    }

    // ── Style application ─────────────────────────────────────────────────────
    @ViewBuilder
    private func applyStyle<V: View>(_ view: V, _ style: JCStyle?, _ ctx: JCBindingContext) -> some View {
        // Note: the expanded Dynamic Island is capped at ~144pt by iOS; minHeight
        // lets a content-light container fill toward that cap (nil = no-op).
        return view
            .padding(style?.padding.map { CGFloat($0) } ?? 0)
            .frame(width: style?.width.map { CGFloat($0) },
                   height: style?.height.map { CGFloat($0) })
            .frame(minHeight: style?.minHeight.map { CGFloat($0) }, alignment: .top)
            .opacity(style?.opacity ?? 1)
    }
}

// ── Small helpers ────────────────────────────────────────────────────────────

private func jcIndexed<T>(_ items: [T]) -> [(Int, T)] { Array(items.enumerated()) }
private func jcSpacing(_ n: JCNode) -> CGFloat { CGFloat(n.double("spacing") ?? 6) }
private func jcScale(_ n: JCNode) -> Double {
    // progress/gauge values may be 0..1 or 0..100; `scale` (default 1) lets the
    // author say 100. Heuristic: if no scale given and value>1 looks like a pct.
    n.double("scale") ?? 1
}
private func jcClamp01(_ v: Double) -> Double { max(0, min(1, v)) }

private func jcHAlign(_ s: String?) -> HorizontalAlignment {
    switch s { case "center": return .center; case "trailing": return .trailing; default: return .leading }
}
private func jcVAlign(_ s: String?) -> VerticalAlignment {
    switch s { case "top": return .top; case "bottom": return .bottom; case "firstBaseline": return .firstTextBaseline; default: return .center }
}
private func jcWeight(_ s: String) -> Font.Weight {
    switch s {
    case "ultraLight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .regular
    }
}
private func jcParseDate(_ v: JCJSON?) -> Date? {
    guard let v = v else { return nil }
    if let n = v.asDouble, n > 0 {
        // epoch seconds (>1e12 → ms)
        return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
    }
    if let s = v.asString {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
    }
    return nil
}

/// A line/area path for sparkline points, normalized to its frame.
struct JCSparklineShape: Shape {
    let points: [Double]
    let filled: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count > 1 else { return p }
        let lo = points.min() ?? 0, hi = points.max() ?? 1
        let span = hi - lo == 0 ? 1 : hi - lo
        let stepX = rect.width / CGFloat(points.count - 1)
        func pt(_ i: Int) -> CGPoint {
            let y = rect.height - CGFloat((points[i] - lo) / span) * rect.height
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
        p.move(to: pt(0))
        for i in 1..<points.count { p.addLine(to: pt(i)) }
        if filled {
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()
        }
        return p
    }
}

/// Type-erased Shape so a node can pick its clip shape at runtime. (Named JC* to
/// avoid shadowing SwiftUI's own iOS-16 `AnyShape` and any deployment ambiguity.)
struct JCAnyShape: Shape {
    private let pathFn: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { pathFn = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { pathFn(rect) }
}

// ── Top-level custom design view (lock screen + region routing) ──────────────

/// Renders the cached design for `mode == "custom"`. Loads `design-<id>.json`
/// from the App Group; decodes; falls back to (app name + data.title) when the
/// design is missing/corrupt. Never crashes, never blank.
@available(iOS 16.2, *)
struct JCDesignView: View {
    let st: JarvisActivityAttributes.ContentState
    /// Which presentation node to render. `.lockScreen` uses lockScreen ?? expanded.
    var presentation: JCPresentation = .lockScreen

    enum JCPresentation { case lockScreen, expanded, compactLeading, compactTrailing, minimal }

    /// Compact / minimal slots are tiny — their fallback is just the orb.
    private var isCompact: Bool {
        switch presentation {
        case .compactLeading, .compactTrailing, .minimal: return true
        default: return false
        }
    }

    var body: some View {
        if let design = JCDesignCache.load(st.designId) {
            let ctx = JCBindingContext(dataJSON: st.data)
            let tint = jcParseColor(design.tint) ?? jcCodingColor("working")
            let renderer = JCDesignRenderer(tint: tint)
            let node = pickNode(design)
            content(renderer, node, ctx)
        } else {
            JCDesignFallback(st: st, compact: isCompact)
        }
    }

    @ViewBuilder
    private func content(_ r: JCDesignRenderer, _ node: JCNode?, _ ctx: JCBindingContext) -> some View {
        if node == nil {
            JCDesignFallback(st: st, compact: isCompact)
        } else {
            switch presentation {
            case .lockScreen, .expanded:
                r.render(node, ctx)
                    .padding(.horizontal, 16).padding(.vertical, 13)
            default:
                r.render(node, ctx)
            }
        }
    }

    private func pickNode(_ d: JCDesign) -> JCNode? {
        switch presentation {
        case .lockScreen: return d.presentations.lockScreen ?? d.presentations.expanded
        case .expanded: return d.presentations.expanded
        case .compactLeading: return d.presentations.compactLeading
        case .compactTrailing: return d.presentations.compactTrailing
        case .minimal: return d.presentations.minimal
        }
    }
}

/// Fallback when the design is missing/corrupt: the app name + an optional
/// `data.title` so the activity is never blank and never crashes.
@available(iOS 16.2, *)
struct JCDesignFallback: View {
    let st: JarvisActivityAttributes.ContentState
    var compact: Bool = false
    private var title: String? {
        let ctx = JCBindingContext(dataJSON: st.data)
        return ctx.data["title"]?.asString
    }
    var body: some View {
        if compact {
            JarvisOrb(state: "idle", size: 22)
        } else {
            HStack(spacing: 10) {
                JarvisOrb(state: "idle", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    if let t = title, !t.isEmpty {
                        Text(t).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

@available(iOS 16.2, *)
struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            JarvisLockScreen(st: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: jcWidgetURL(context.state)))
        } dynamicIsland: { context in
            let st = context.state
            // Custom data-driven design (Dynamic Island Designs). A `regions`
            // top-level node maps to the native DI regions; otherwise the whole
            // expanded tree lands in the bottom region. Compact/minimal pull from
            // their presentation nodes, with the orb/fallback as a safety net.
            if st.mode == "custom" {
                let design = JCDesignCache.load(st.designId)
                let ctx = JCBindingContext(dataJSON: st.data)
                let tint = design.flatMap { jcParseColor($0.tint) } ?? jcCodingColor("working")
                let node = design?.presentations.expanded
                let isRegions = (node?.type == "regions")
                // Declare the four regions inline (mirrors the coding pattern) so
                // the @DynamicIslandExpandedContentBuilder body is straight-line;
                // all branching lives inside each region's ViewBuilder closure.
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        if isRegions {
                            JCDesignRenderer(tint: tint).render(node?.node("leading"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        if isRegions {
                            JCDesignRenderer(tint: tint).render(node?.node("trailing"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.center) {
                        if isRegions {
                            JCDesignRenderer(tint: tint).render(node?.node("center"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        // Small safety inset so wide content (bars/lists) doesn't
                        // run into the island's rounded corners; designs should
                        // still pad their own root (see the skill's layout rules).
                        Group {
                            if isRegions {
                                JCDesignRenderer(tint: tint).render(node?.node("bottom"), ctx)
                            } else if let node = node {
                                JCDesignRenderer(tint: tint).render(node, ctx)
                            } else {
                                JCDesignFallback(st: st)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                } compactLeading: {
                    JCDesignView(st: st, presentation: .compactLeading)
                } compactTrailing: {
                    JCDesignView(st: st, presentation: .compactTrailing)
                } minimal: {
                    JCDesignView(st: st, presentation: .minimal)
                }
                .widgetURL(URL(string: jcWidgetURL(st)))
            }
            return DynamicIsland {
                // Header left-aligned: orb + JARVIS/Connected sit together on the
                // leading side (a little padding off the orb), state pill trailing.
                DynamicIslandExpandedRegion(.leading) {
                    if st.mode == "coding" {
                        HStack(spacing: 9) {
                            JarvisOrb(state: "idle", size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Claude Code").font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                (Text("\(st.sessionTotal) sessions").foregroundColor(.white.opacity(0.55))
                                 + Text(st.waitingCount > 0 ? " · \(st.waitingCount) waiting" : "")
                                    .foregroundColor(jcCodingColor("waiting")))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.leading, 4)
                    } else {
                        HStack(spacing: 9) {
                            JarvisOrb(state: st.state, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("JARVIS").font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(.white)
                                HStack(spacing: 4) {
                                    Circle().fill(st.connected ? Color.green : Color.gray)
                                        .frame(width: 5, height: 5)
                                    Text(st.connected ? "Connected" : "Offline")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if st.mode == "coding" {
                        JCUsageBlock(st: st).padding(.trailing, 4)
                    } else {
                        jcStatePill(st.state).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if st.mode == "coding" {
                        VStack(alignment: .leading, spacing: 9) {
                            JCSegBar(sessions: jcDecodeSessions(st.sessions))
                            JCLegend(sessions: jcDecodeSessions(st.sessions), total: st.entryTotal)
                        }
                    } else {
                        // Both the expanded island AND the lock-screen banner are
                        // height-capped by the system, so the waveform is dropped
                        // from both. State is conveyed by the pill + animating orb,
                        // so the freed room goes to the content.
                        VStack(spacing: 6) {
                            JarvisConvo(st: st)
                            JarvisDevices(st: st)
                        }
                    }
                }
            } compactLeading: {
                if st.mode == "coding" {
                    JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
                } else {
                    JarvisOrb(state: st.state, size: 24)
                }
            } compactTrailing: {
                if st.mode == "coding" {
                    JCCompactFleetBar(sessions: jcDecodeSessions(st.sessions))
                } else {
                    Text(jcStateLabel(st.state))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(jcStateColor(st.state))
                }
            } minimal: {
                if st.mode == "coding" {
                    JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
                } else {
                    JarvisOrb(state: st.state, size: 22)
                }
            }
            .widgetURL(URL(string: jcWidgetURL(st)))
        }
    }
}

/// Deep-link target for a tap on the activity. Coding → coding tab; custom →
/// the island tab; voice (and fallback) → the Voice screen.
@available(iOS 16.2, *)
private func jcWidgetURL(_ st: JarvisActivityAttributes.ContentState) -> String {
    switch st.mode {
    case "coding": return "jarviscopilot://coding"
    case "custom": return "jarviscopilot://island"
    default: return "jarviscopilot://voice"
    }
}

/// The Lock Screen / banner presentation — the full layout: header (orb +
/// JARVIS / Connected + state pill), waveform, conversation panel, devices.
@available(iOS 16.2, *)
struct JarvisLockScreen: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        if st.mode == "custom" {
            // Data-driven custom design (Dynamic Island Designs). Renders the
            // cached layout tree; falls back to app name + data.title if missing.
            JCDesignView(st: st, presentation: .lockScreen)
        } else if st.mode == "coding" {
            // Coding fleet view (Scheme 4): header + segmented bar + legend.
            JarvisCodingBody(st: st)
                .padding(.horizontal, 16).padding(.vertical, 13)
        } else {
            // No waveform here: the lock-screen banner is height-capped too, and a
            // two-row conversation was pushing the devices strip off the bottom.
            // The pill already shows state, so the room goes to the content.
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    JarvisOrb(state: st.state, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("JARVIS").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                        HStack(spacing: 5) {
                            Circle().fill(st.connected ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(st.connected ? "Connected" : "Offline")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    jcStatePill(st.state)
                }
                JarvisConvo(st: st)
                JarvisDevices(st: st)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget {
        JarvisWidget()
        // Dynamic Island / Lock Screen Live Activity (iOS 16.2+).
        if #available(iOS 16.2, *) {
            JarvisLiveActivity()
        }
        // Control Center button — only on iOS 18+, where Controls exist.
        if #available(iOS 18.0, *) {
            JarvisVoiceControl()
        }
    }
}

// MARK: - Embedded app-icon orb
// The JARVIS orb shown in the Live Activity is the real app icon, embedded as
// base64 and decoded once at load — avoids adding an asset catalog (and its
// project-file wiring) to the extension. ~144px; displayed at ≄24–58pt.
private let jarvisOrbUIImage: UIImage? = UIImage(data: Data(base64Encoded: jarvisOrbB64) ?? Data())
private let jarvisOrbB64 = "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"
