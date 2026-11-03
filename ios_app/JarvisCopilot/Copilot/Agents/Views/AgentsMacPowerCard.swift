import SwiftUI

/// The MacBook card, under the plan usage: awake or asleep (or waking), what
/// holds it up, its battery, and Wake Mac / Keep awake / Let it sleep / Unlock
/// Mac. The 15-minute "check for wake requests" timer lives in its ⋯ menu.
struct AgentsMacPowerCard: View {
    let mac: AgentMacPower
    let store: AgentsStore

    @State private var error: String?

    private var busy: Bool { store.macBusy.contains(mac.deviceId) }

    var body: some View {
        // Ticks so "Waking…" turns into the deep-sleep line and "last seen" ages.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            JcCard(padding: 0) {
                header(now: context.date)
                JcRowSeparator()
                JcRow(symbol: "sun.max", title: "Keep awake",
                      subtitle: "Stays awake until you turn it off", last: true) {
                    Toggle("Keep awake", isOn: Binding(
                        get: { mac.keepAwake },
                        set: { on in run(.keepAwake(on)) }))
                        .labelsHidden()
                        .tint(JcTheme.accent)
                }
                JcRowSeparator()
                actions
                if let error {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, JcUnified.cardPadding)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: "laptopcomputer")
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(AgentsMacPowerCopy.stateLine(mac, now: now))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let battery = mac.battery {
                HStack(spacing: 4) {
                    JcIcon(mac.onAC == true ? "battery.100.bolt" : "battery.75", size: 13)
                    Text("\(battery)%").monospacedDigit()
                }
                .font(.system(size: 12.5))
                .foregroundStyle(JcTheme.muted)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery \(battery) percent\(mac.onAC == true ? ", charging" : "")")
            }
            Menu {
                Toggle("Check for wake requests while asleep", isOn: Binding(
                    get: { mac.timerOn },
                    set: { on in run(.timer(on)) }))
            } label: {
                JcIcon("ellipsis", size: 15)
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(mac.name) settings")
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if mac.isAwake {
                JcSmallAction("Let it sleep", symbol: "moon", busy: busy) { run(.letSleep) }
                JcSmallAction("Unlock Mac", symbol: "lock.open", busy: busy) { run(.unlock) }
            } else {
                JcSmallAction("Wake Mac", symbol: "power", busy: busy) { run(.wake) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
    }

    private func run(_ action: AgentsStore.MacPowerAction) {
        error = nil
        Task { error = await store.macPower(mac, action) }
    }
}

/// The MacBook card's words, kept pure for the tests.
enum AgentsMacPowerCopy {
    /// After this long without an answer the Mac is likely in deep sleep, where
    /// only the 15-minute timer wakes it.
    static let slowWakeAfter: TimeInterval = 60
    /// The server stops honouring a wake intent this old.
    static let wakeExpiresAfter: TimeInterval = 1200

    /// "Awake · Claude working", "Asleep · last seen 5 min ago", "Waking…".
    static func stateLine(_ mac: AgentMacPower, now: Date = Date()) -> String {
        if mac.isAwake {
            return reason(mac.reason).map { "Awake · \($0)" } ?? "Awake"
        }
        if let asked = mac.wakeRequestedAt {
            let waited = now.timeIntervalSince(asked)
            if waited < wakeExpiresAfter {
                return waited > slowWakeAfter ? "Waking… up to 15 min if it's in deep sleep" : "Waking…"
            }
        }
        let base = mac.state == .sleeping ? "Asleep" : "Offline"
        guard let seen = mac.seenAt else { return base }
        return "\(base) · last seen \(ago(seen, now: now))"
    }

    /// What holds it awake, in words.
    static func reason(_ reason: String) -> String? {
        switch reason {
        case "manual": return "Keep awake on"
        case "session": return "Claude working"
        case "grace": return "Staying up after the last turn"
        case "remote": return "Woken from your phone"
        case "password": return "Waiting on a password"
        default: return nil
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60)) min ago" }
        if delta < 86_400 { return "\(Int(delta / 3600)) h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A Mac password prompt under Needs you: what asked, how long is left, Allow
/// (Face ID, then the signed yes) and Deny.
struct AgentsMacPasswordCard: View {
    let request: MacPasswordRequest
    let store: AgentsStore

    @State private var busy = false
    @State private var error: String?

    private var macName: String {
        store.macs.first { $0.deviceId == request.deviceId }?.name ?? "Your Mac"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = request.expires <= context.date
            JcCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        PulsingDot(color: JcTheme.amber, size: 7)
                        Text(MacPasswordApproval.title(kind: request.kind))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        Spacer(minLength: 0)
                        Text("\(macName) · \(MacPasswordApproval.countdown(request.expires, now: context.date))")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                    }
                    if !request.context.isEmpty {
                        Text(request.context)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(AgentPane.paneText)
                            .lineLimit(6)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentPane.pane, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    HStack(spacing: 10) {
                        Button("Allow") { answer(allow: true) }
                            .buttonStyle(.jcGlass(tint: JcTheme.success, full: true))
                        Button("Deny") { answer(allow: false) }
                            .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                    }
                    .disabled(busy || expired)
                    if let error {
                        Text(error)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.danger)
                    }
                }
            }
        }
    }

    private func answer(allow: Bool) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            error = await store.answerMacPassword(request, allow: allow)
        }
    }
}
