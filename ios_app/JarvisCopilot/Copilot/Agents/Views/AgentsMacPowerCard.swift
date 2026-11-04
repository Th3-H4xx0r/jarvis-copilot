import SwiftUI

/// The MacBook card, under the plan usage, drawn like a first-party device
/// card: the Mac's own name, whether it's awake and why, its battery, Keep
/// awake, and the one or two things he can do from here (Wake Mac when it's
/// asleep; Sleep and Unlock when it's awake). The 15-minute "check for wake
/// requests" timer and the pairing code live in its ⋯ menu.
struct AgentsMacPowerCard: View {
    let mac: AgentMacPower
    let store: AgentsStore

    @State private var error: String?
    /// The action this card started, so only its button shows progress.
    @State private var pending: AgentsStore.MacPowerAction?
    @State private var taps = 0

    private var busy: Bool { store.macBusy.contains(mac.deviceId) }
    private var name: String { AgentsMacPowerCopy.friendlyName(mac.name) }

    var body: some View {
        // Ticks so "Waking…" turns into the deep-sleep line and "last seen" ages.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let status = AgentsMacPowerCopy.status(mac, now: context.date)
            JcCard(padding: 0) {
                header(status)
                JcRowSeparator()
                JcRow(symbol: "cup.and.saucer", title: "Keep awake",
                      subtitle: AgentsMacPowerCopy.keepAwakeSubtitle(on: mac.keepAwake), last: true) {
                    Toggle("Keep awake", isOn: Binding(
                        get: { mac.keepAwake },
                        set: { on in run(.keepAwake(on)) }))
                        .labelsHidden()
                        .tint(JcTheme.accent)
                        .accessibilityHint(AgentsMacPowerCopy.keepAwakeSubtitle(on: mac.keepAwake))
                }
                JcRowSeparator()
                actions
                if let error {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.footnote)
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, JcUnified.cardPadding)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: error)
        .animation(.snappy(duration: 0.25), value: mac.isAwake)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(trigger: error) { _, new in new == nil ? nil : .error }
    }

    // MARK: header

    private func header(_ status: AgentsMacPowerCopy.Status) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(status.tone == .awake ? JcTheme.text : JcTheme.muted)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    if let battery = mac.battery { batteryView(battery) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    MacStatusDot(tone: status.tone)
                    if let detail = status.detail {
                        Text("\(Text(status.label).foregroundStyle(JcTheme.text)) · \(detail)")
                    } else {
                        Text(status.label).foregroundStyle(JcTheme.text)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            menu
        }
        .padding(.leading, JcUnified.cardPadding)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
    }

    private func batteryView(_ level: Int) -> some View {
        let charging = mac.onAC == true
        let low = level <= 20 && !charging
        return HStack(spacing: 5) {
            Text("\(level)%")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(JcTheme.muted)
            Image(systemName: AgentsMacPowerCopy.batterySymbol(level: level, charging: charging))
                .font(.footnote)
                .foregroundStyle(charging ? JcTheme.success : low ? JcTheme.danger : JcTheme.muted)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
    }

    private var menu: some View {
        Menu {
            Toggle("Check for wake requests while asleep", isOn: Binding(
                get: { mac.timerOn },
                set: { on in run(.timer(on)) }))
            // What the Mac shows when it pairs for password approvals: they must match.
            Text("Pairing code \(MacPasswordApproval.pairingCode() ?? "unavailable")")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(name) options")
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 10) {
            if mac.isAwake {
                actionButton(.letSleep, title: "Sleep", symbol: "moon.fill",
                             hint: "Lets the Mac go to sleep now")
                actionButton(.unlock, title: "Unlock", symbol: "lock.open.fill",
                             hint: "Asks the Mac to unlock its screen")
                MacShareScreenButton {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.on.rectangle").font(.subheadline.weight(.semibold))
                        Text("Screen").lineLimit(1)
                    }
                }
                .buttonStyle(MacActionButtonStyle(prominent: false))
                .accessibilityLabel("Share screen")
                .accessibilityHint("Watch and control the Mac's screen live")
            } else {
                actionButton(.wake, title: "Wake Mac", symbol: "power", prominent: true,
                             hint: "Asks the Mac to wake up. It can take up to 15 minutes from deep sleep")
            }
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func actionButton(_ action: AgentsStore.MacPowerAction, title: String, symbol: String,
                              prominent: Bool = false, hint: String) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 7) {
                if busy && pending == action {
                    ProgressView().controlSize(.small).tint(prominent ? JcAccent.onFill : JcButton.label)
                } else {
                    Image(systemName: symbol).font(.subheadline.weight(.semibold))
                }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(MacActionButtonStyle(prominent: prominent))
        .disabled(busy)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func run(_ action: AgentsStore.MacPowerAction) {
        error = nil
        pending = action
        taps += 1
        Task {
            error = await store.macPower(mac, action)
            if pending == action { pending = nil }
        }
    }
}

/// The card's (and the password sheet's) full-width rounded buttons — the look
/// every button in the app now has (`JcButton`): the main-button fill for the
/// one thing to do, a quiet grey fill for the rest.
struct MacActionButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, style: self)
    }

    private struct Styled: View {
        let configuration: Configuration
        let style: MacActionButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(style.prominent ? JcAccent.onFill : JcButton.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: style.height)
                .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous),
                                 prominent: style.prominent)
                .opacity(isEnabled ? (configuration.isPressed ? JcButton.pressedOpacity : 1)
                                   : JcButton.disabledOpacity)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The small dot before Awake / Waking… / Asleep.
private struct MacStatusDot: View {
    let tone: AgentsMacPowerCopy.Tone

    var body: some View {
        Group {
            switch tone {
            case .awake: Circle().fill(JcTheme.success).frame(width: 7, height: 7)
            case .waking: PulsingDot(color: JcTheme.amber, size: 7)
            case .asleep: Circle().fill(JcTheme.muted).frame(width: 7, height: 7)
            case .offline: Circle().strokeBorder(JcTheme.muted, lineWidth: 1.5).frame(width: 7, height: 7)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        .accessibilityHidden(true)
    }
}

/// A Mac password prompt under Needs you, as one compact row: what asked, which
/// Mac and how long is left. Tapping it opens the password sheet.
struct AgentsMacPasswordRow: View {
    let request: MacPasswordRequest
    let macName: String
    var last = false
    let open: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            JcRow(symbol: MacPasswordSheetCopy.symbol(kind: request.kind),
                  title: MacPasswordSheetCopy.title(kind: request.kind),
                  subtitle: "\(macName) · \(MacPasswordApproval.countdown(request.expires, now: context.date))",
                  subtitleLines: 1, last: last, action: open)
                .accessibilityHint("Opens the request to allow or deny it")
        }
    }
}

// MARK: - Words

/// The MacBook card's words, kept pure for the tests.
enum AgentsMacPowerCopy {
    /// After this long without an answer the Mac is likely in deep sleep, where
    /// only the 15-minute timer wakes it.
    static let slowWakeAfter: TimeInterval = 60
    /// The server stops honouring a wake intent this old.
    static let wakeExpiresAfter: TimeInterval = 1200
    /// "Keep awake" turns itself off after this (`mac_power.py` KEEP_AWAKE_MAX).
    static let keepAwakeHours = 12

    enum Tone: Equatable { case awake, waking, asleep, offline }

    /// The card's status: the dot's tone, its word, and what follows the dot.
    struct Status: Equatable {
        let tone: Tone
        let label: String
        let detail: String?
    }

    static func status(_ mac: AgentMacPower, now: Date = Date()) -> Status {
        if mac.isAwake {
            return Status(tone: .awake, label: "Awake", detail: reason(mac.reason))
        }
        if let asked = mac.wakeRequestedAt {
            let waited = now.timeIntervalSince(asked)
            if waited < wakeExpiresAfter {
                return Status(tone: .waking, label: "Waking…",
                              detail: waited > slowWakeAfter ? "up to 15 min from deep sleep" : nil)
            }
        }
        let asleep = mac.state == .sleeping
        return Status(tone: asleep ? .asleep : .offline, label: asleep ? "Asleep" : "Offline",
                      detail: mac.seenAt.map { "last seen \(ago($0, now: now))" })
    }

    /// "Awake · Claude is working", "Asleep · last seen 5 min ago", "Waking…".
    static func stateLine(_ mac: AgentMacPower, now: Date = Date()) -> String {
        let s = status(mac, now: now)
        return s.detail.map { "\(s.label) · \($0)" } ?? s.label
    }

    /// What holds it awake, in words.
    static func reason(_ reason: String) -> String? {
        switch reason {
        case "manual": return "Kept awake"
        case "session": return "Claude is working"
        case "grace": return "A session just finished"
        case "remote": return "Woken from iPhone"
        case "password": return "Waiting for a password"
        default: return nil
        }
    }

    static func keepAwakeSubtitle(on: Bool) -> String {
        on ? "On · turns off after \(keepAwakeHours) hours"
            : "Stays awake for up to \(keepAwakeHours) hours"
    }

    /// The SF Symbol for a battery level, with the bolt while it charges.
    static func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// The Mac's name as macOS would show it: "Pranavs-MacBook-Pro.local" →
    /// "Pranav's MacBook Pro". A name that already reads as words is kept.
    static func friendlyName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(6)) }
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return "Your Mac" }
        guard !name.contains(" ") else { return name }

        var parts = name.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        // macOS numbers a clash "Pranavs-MacBook-Pro-2": the name is the same Mac.
        if parts.count > 1, let last = parts.last, Int(last) != nil { parts.removeLast() }

        for (pattern, words) in models {
            let n = pattern.count
            guard parts.count >= n else { continue }
            let tail = parts.suffix(n).map { $0.lowercased() }
            guard tail == pattern else { continue }
            let owner = parts.dropLast(n).joined(separator: " ")
            return owner.isEmpty ? words : "\(possessive(owner)) \(words)"
        }
        return parts.joined(separator: " ")
    }

    /// Hostname endings → the model's words, longest first so "MacBook-Pro"
    /// wins over "MacBook".
    private static let models: [([String], String)] = [
        (["macbook", "pro"], "MacBook Pro"),
        (["macbook", "air"], "MacBook Air"),
        (["imac", "pro"], "iMac Pro"),
        (["mac", "mini"], "Mac mini"),
        (["mac", "studio"], "Mac Studio"),
        (["mac", "pro"], "Mac Pro"),
        (["macbook"], "MacBook"),
        (["imac"], "iMac"),
    ]

    /// The hostname drops the apostrophe macOS put in "Pranav's": put it back.
    private static func possessive(_ owner: String) -> String {
        var owner = owner
        if let first = owner.first, first.isLowercase { owner = first.uppercased() + owner.dropFirst() }
        guard owner.count > 1, owner.hasSuffix("s"), !owner.hasSuffix("'s"), !owner.hasSuffix("’s") else {
            return owner
        }
        return String(owner.dropLast()) + "'s"
    }

    /// The friendly name of the Mac a request came from.
    static func macName(_ deviceId: String, in macs: [AgentMacPower]) -> String {
        friendlyName(macs.first { $0.deviceId == deviceId }?.name ?? "")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60)) min ago" }
        if delta < 86_400 { return "\(Int(delta / 3600)) h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
