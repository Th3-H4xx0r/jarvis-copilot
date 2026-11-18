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
    private var name: String { AgentsMacPowerCopy.cardName(mac.name, os: mac.os) }

    var body: some View {
        // Ticks so "Waking…" turns into the deep-sleep line and "last seen" ages.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let status = AgentsMacPowerCopy.status(mac, now: context.date)
            JcCard(padding: 0) {
                header(status)
                JcRowSeparator()
                if mac.isPC && PowerState.shared.isOn("pc-stats") {
                    // PC Stats: four live numbers and View stats.
                    PcStatsCardSection(deviceId: mac.deviceId, name: name, appDown: mac.isAwake && mac.appRunning == false)
                    JcRowSeparator()
                }
                NavigationLink(value: AgentsRoute.computerTools(deviceId: mac.deviceId, name: name)) {
                    JcRow(symbol: "wrench.and.screwdriver", title: "Tools",
                          subtitle: mac.isAwake ? "Power actions and Jarvis tools, for buttons"
                                                : "Power actions now · tools once it's awake")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Lists the tools you can map to buttons")
                if mac.isPC && PowerState.shared.isOn("remote-desktop") {
                    // The full RDP session (Screen stays the watch-and-steer view).
                    JcRow(symbol: "display", title: "Remote Desktop",
                          subtitle: mac.isAwake ? "The full desktop · Face ID" : "Asleep · it offers Wake first",
                          action: { RdpPresenter.shared.open(deviceId: mac.deviceId, name: name) })
                        .accessibilityHint("Opens a Remote Desktop session after Face ID")
                }
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
            Image(systemName: mac.isPC ? "desktopcomputer" : "laptopcomputer")
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
                if mac.isAwake && mac.appRunning == false {
                    Text(AgentsMacPowerCopy.appDownLine)
                        .font(.footnote)
                        .foregroundStyle(JcTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            if mac.isPC {
                // No dark wake on Windows (nothing to check), no Mac password pairing.
                Text(AgentsMacPowerCopy.wakeLine(mac))
            } else {
                Toggle("Check for wake requests while asleep", isOn: Binding(
                    get: { mac.timerOn },
                    set: { on in run(.timer(on)) }))
                // What the Mac shows when it pairs for password approvals: they must match.
                Text("Pairing code \(MacPasswordApproval.pairingCode() ?? "unavailable")")
            }
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
                             hint: mac.isPC ? "Puts the PC to sleep now" : "Lets the Mac go to sleep now")
                if mac.isPC {
                    actionButton(.lock, title: "Lock", symbol: "lock.fill",
                                 hint: "Locks the PC's screen")
                    // Its helper types the saved password on the lock screen after Face ID here.
                    actionButton(.unlock, title: "Unlock", symbol: "lock.open.fill",
                                 hint: "Unlocks the PC's screen after Face ID")
                } else {
                    actionButton(.unlock, title: "Unlock", symbol: "lock.open.fill",
                                 hint: "Asks the Mac to unlock its screen")
                }
                MacShareScreenButton(deviceId: mac.deviceId) {
                    let layout = compactRow ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 7))
                    layout {
                        Image(systemName: "rectangle.on.rectangle").font(.subheadline.weight(.semibold))
                        Text("Screen").lineLimit(1).minimumScaleFactor(0.85)
                            .font(compactRow ? .caption.weight(.semibold) : nil)
                    }
                }
                .buttonStyle(MacActionButtonStyle(prominent: false))
                .accessibilityLabel("Share screen")
                .accessibilityHint(mac.isPC ? "Watch and control the PC's screen live"
                                            : "Watch and control the Mac's screen live")
            } else {
                actionButton(.wake, title: AgentsMacPowerCopy.wakeTitle(os: mac.os), symbol: "power",
                             prominent: true,
                             hint: mac.isPC ? "Sends the PC a wake signal over Wi-Fi from your other computer"
                                            : "Asks the Mac to wake up. It can take up to 15 minutes from deep sleep")
                    .disabled(mac.isPC && mac.wakeCapable == false)
            }
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private var compactRow: Bool { mac.isPC && mac.isAwake }

    private func actionButton(_ action: AgentsStore.MacPowerAction, title: String, symbol: String,
                              prominent: Bool = false, hint: String) -> some View {
        Button { run(action) } label: {
            // The awake PC has four buttons in the row: icon over label so they fit.
            let layout = compactRow ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 7))
            layout {
                if busy && pending == action {
                    JcLoader(size: 16).foregroundStyle(prominent ? JcAccent.onFill : JcButton.label)
                } else {
                    Image(systemName: symbol).font(.subheadline.weight(.semibold))
                }
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
                    .font(compactRow ? .caption.weight(.semibold) : nil)
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
                  title: MacPasswordSheetCopy.title(for: request),
                  subtitle: [MacPasswordSheetCopy.subtitle(for: request) ?? macName,
                             MacPasswordApproval.countdown(request.expires, now: context.date)].joined(separator: " · "),
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
    /// A PC wakes in seconds or not at all (no deep-sleep timer like the Mac's): stop "Waking…" sooner.
    static let pcWakeExpiresAfter: TimeInterval = 120
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
            if waited < (mac.isPC ? pcWakeExpiresAfter : wakeExpiresAfter) {
                // Jarvis on the PC only starts after he signs in: a woken PC can sit at the sign-in screen.
                let slow = mac.isPC ? "It may be at the sign-in screen" : "up to 15 min from deep sleep"
                return Status(tone: .waking, label: "Waking…", detail: waited > slowWakeAfter ? slow : nil)
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

    /// "Wake Mac" / "Wake PC".
    static func wakeTitle(os: String) -> String { os == "windows" ? "Wake PC" : "Wake Mac" }

    /// jc-client up, the Jarvis app gone: Screen, Remote Desktop and PC Stats need it.
    static let appDownLine = "The Jarvis app isn't running on this PC · open it there"

    /// What the card offers right now, in order (pure, for the tests): an awake PC sleeps, locks
    /// and unlocks; an awake Mac sleeps and unlocks; asleep, either wakes.
    static func actions(for mac: AgentMacPower) -> [AgentsStore.MacPowerAction] {
        if mac.isAwake { return mac.isPC ? [.letSleep, .lock, .unlock] : [.letSleep, .unlock] }
        return [.wake]
    }

    /// The PC's ⋯ line about waking it.
    static func wakeLine(_ mac: AgentMacPower) -> String {
        switch mac.wakeCapable {
        case .some(true): return "Wakes over Wi-Fi from your other computer"
        case .some(false): return mac.wakeReason ?? "This PC's Wi-Fi adapter can't be woken remotely"
        case .none: return "Wake over Wi-Fi not checked yet"
        }
    }

    /// The computer's name for the card: a PC's own name as Windows has it ("Your PC" when
    /// missing); a Mac's via `friendlyName(_:)`.
    static func cardName(_ raw: String, os: String) -> String {
        guard os == "windows" else { return friendlyName(raw) }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An offline PC used to come back as the server's generic "Mac".
        return name.isEmpty || name == "Your Mac" || name == "Mac" ? "Your PC" : name
    }

    /// "PC" for the Windows PC, else "Mac" — what status lines and popups call the computer.
    static func noun(isPC: Bool) -> String { isPC ? "PC" : "Mac" }

    /// Whether the computer with this id is the Windows PC (false when unknown — the Mac, as before).
    @MainActor static func isPC(_ deviceId: String?) -> Bool {
        guard let deviceId, !deviceId.isEmpty else { return false }
        return AgentsStore.shared.macs.first { $0.deviceId == deviceId }?.isPC ?? false
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
