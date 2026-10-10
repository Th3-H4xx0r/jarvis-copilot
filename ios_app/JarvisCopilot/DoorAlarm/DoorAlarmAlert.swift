import SwiftUI
import UIKit

/// The alarm popup: when a door trips the alarm (entry delay or going off), a card comes up over the
/// whole app — like the car's approval card — with a big per-second countdown, the door, Disarm with
/// Face ID and, while the siren sounds, Silence. The server pops it (`door_show_alarm`) the moment a
/// door trips; it also appears whenever the app comes forward during an alarm (a tapped notification).
@MainActor
final class DoorAlarmAlert: ObservableObject {
    static let shared = DoorAlarmAlert()

    @Published private(set) var shown = false
    let store: DoorAlarmStore
    private var active = false
    private var window: UIWindow?
    private var poller: Task<Void, Never>?
    /// The alarm the user hid ("since" of that state) — it comes back only for a new trip.
    private var hiddenSince: Date?

    init(store: DoorAlarmStore? = nil) {
        self.store = store ?? DoorAlarmStore.shared
    }

    var alarm: DoorAlarmInfo? { store.state?.alarm }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            active = true
            Task { await refresh() }
        case .background:
            active = false
            update()
        default:
            break
        }
    }

    /// Read the alarm now and show or hide the card.
    func refresh() async {
        guard store.api.api.isPaired else { return }
        await store.load()
        update()
    }

    func hide() {
        hiddenSince = alarm?.since
        update()
    }

    private func update() {
        let alerting = alarm?.isAlerting == true
        if !alerting { hiddenSince = nil }
        let wanted = active && alerting && (hiddenSince == nil || hiddenSince != alarm?.since)
        if wanted { present() } else { dismiss() }
        shown = wanted
    }

    // MARK: Window + live updates

    private func present() {
        if poller == nil {
            // While it's up, follow the server every second: a disarm anywhere closes it.
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    await self.store.load()
                    self.update()
                }
            }
        }
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: DoorAlarmAlertCard(center: self, store: store))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 2
        made.backgroundColor = .clear
        made.rootViewController = host
        made.isHidden = false
        window = made
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    private func dismiss() {
        poller?.cancel()
        poller = nil
        window?.isHidden = true
        window = nil
    }
}

/// The big countdown: seconds left until the alarm goes off (entry) or since it went off.
struct DoorCountdown: View {
    let alarm: DoorAlarmInfo
    var size: CGFloat = 96

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(alarm, at: context.date))
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(alarm.state == "arming" ? JcTheme.accent : JcTheme.danger)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: Self.text(alarm, at: context.date))
                .accessibilityLabel(Self.text(alarm, at: context.date))
        }
    }

    /// m:ss (or just seconds under a minute) left on the current countdown; "ALARM" once it went off.
    static func text(_ alarm: DoorAlarmInfo, at now: Date) -> String {
        if alarm.state == "triggered" { return "ALARM" }
        let left = max(0, Int((alarm.deadline?.timeIntervalSince(now) ?? Double(alarm.secondsLeft ?? 0)).rounded(.up)))
        return left >= 60 ? String(format: "%d:%02d", left / 60, left % 60) : "\(left)"
    }
}

struct DoorAlarmAlertCard: View {
    @ObservedObject var center: DoorAlarmAlert
    @ObservedObject var store: DoorAlarmStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            if let alarm = store.state?.alarm, alarm.isAlerting {
                card(alarm)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: store.state?.alarm.state)
    }

    private func card(_ alarm: DoorAlarmInfo) -> some View {
        VStack(spacing: 0) {
            DoorHubView(state: .alert, compact: false)
                .frame(height: 150)
                .allowsHitTesting(false)
            Text(alarm.state == "triggered" ? "Alarm going off" : "Door opened")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.top, 4)
            Text(alarm.contactName ?? "A door")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            DoorCountdown(alarm: alarm, size: alarm.state == "triggered" ? 64 : 104)
                .padding(.top, 6)
            Text(alarm.state == "triggered" ? (alarm.sirenOn ? "Siren on" : "Siren stopped — still armed")
                                            : "seconds to disarm")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Button { Task { await store.disarm() } } label: {
                    HStack(spacing: 10) {
                        if store.busy == "disarm" { ProgressView().tint(JcTheme.danger) } else {
                            Image(systemName: "faceid")
                            Text("Disarm with Face ID")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                .disabled(store.busy == "disarm")
                if alarm.state == "triggered" && alarm.sirenOn {
                    Button { Task { await store.silence() } } label: {
                        Label("Silence siren", systemImage: "speaker.slash.fill").frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(.jcGlass(tint: JcTheme.amber, full: true))
                    .disabled(store.busy == "silence")
                }
                Button("Hide") { center.hide() }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(JcTheme.bg, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.6), lineWidth: 1.5))
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
    }
}
