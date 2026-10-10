import SwiftUI
import UIKit

/// Disarm / silence requests Jarvis made, waiting for Face ID on this iPhone — the door alarm's twin
/// of `CarApprovals`. Checked when the app comes forward (a tapped notification lands here) and when
/// the server calls `door_show_approvals`. Shown on a card in its own window, above any sheet.
@MainActor
final class DoorApprovals: ObservableObject {
    static let shared = DoorApprovals()

    /// The only actions this app signs, in its own words — never whatever text a server sent.
    static let titles = ["disarm": "Disarm the door alarm", "silence": "Silence the siren"]

    struct Answer: Equatable {
        let text: String
        let ok: Bool
    }

    @Published private(set) var pending: [DoorApproval] = []
    @Published private(set) var current: DoorApproval?
    @Published private(set) var working = false
    @Published private(set) var answer: Answer?

    let api: DoorAlarmAPI
    let approver: ToyotaApprover
    private var active = false
    private var window: UIWindow?
    private var expiry: Task<Void, Never>?

    init(api: DoorAlarmAPI = DoorAlarmAPI(), approver: ToyotaApprover? = nil) {
        self.api = api
        self.approver = approver ?? ToyotaApprover.shared
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            active = true
            Task { await refresh() }
        case .background:
            active = false
            updateWindow()
        default:
            break
        }
    }

    func refresh() async {
        guard api.api.isPaired else { return }
        do {
            pending = try await api.approvals()
        } catch {
            if wasCancelled(error) { return }
        }
        if !working, answer == nil { show(pending.first) }
        updateWindow()
    }

    func approve(_ approval: DoorApproval) async {
        guard !working else { return }
        guard let title = Self.titles[approval.command] else {
            await finish(approval, Answer(text: "Jarvis asked for something this app doesn't approve.", ok: false))
            return
        }
        working = true
        do {
            let proof = try await approver.proof(for: approval.command, title: title, nonce: approval.id,
                                                 domain: DoorAlarmAPI.domain)
            let state = try await api.approve(approval, proof: proof)
            await finish(approval, Answer(text: approval.command == "disarm" ? "Disarmed" : "Siren silenced",
                                          ok: state.alarm.state == "disarmed" || approval.command == "silence"))
        } catch CarSignError.cancelled {
            working = false
        } catch {
            if case .http(403, _)? = error as? APIError { approver.forgetRegistration() }
            await finish(approval, Answer(text: apiErrorMessage(error), ok: false))
        }
        await DoorAlarmStore.shared.load()
    }

    func deny(_ approval: DoorApproval) async {
        guard !working else { return }
        working = true
        try? await api.deny(approval)
        pending.removeAll { $0.id == approval.id }
        working = false
        show(pending.first)
        updateWindow()
    }

    private func finish(_ approval: DoorApproval, _ result: Answer) async {
        answer = result
        pending.removeAll { $0.id == approval.id }
        working = false
        try? await Task.sleep(for: .seconds(1.8))
        answer = nil
        show(pending.first)
        updateWindow()
    }

    private func show(_ approval: DoorApproval?) {
        current = approval
        expiry?.cancel()
        guard let approval else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, approval.expiresInSeconds)))
            guard !Task.isCancelled, let self, self.current?.id == approval.id, !self.working else { return }
            self.pending.removeAll { $0.id == approval.id }
            self.show(self.pending.first)
            self.updateWindow()
        }
    }

    private func updateWindow() {
        if active, current != nil { present() } else { dismiss() }
    }

    private func present() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: DoorApprovalCard(center: self))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        made.backgroundColor = .clear
        made.rootViewController = host
        made.isHidden = false
        window = made
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    private func dismiss() {
        window?.isHidden = true
        window = nil
    }
}

/// "Disarm the door alarm?" over everything: the hub, the action, time left, Approve with Face ID,
/// and Deny underneath. The app's black glass card, no gradients — like the car's approval card.
struct DoorApprovalCard: View {
    @ObservedObject var center: DoorApprovals

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6).ignoresSafeArea()
            if let approval = center.current {
                DoorApprovalSheet(center: center, approval: approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.current?.id)
    }
}

private struct DoorApprovalSheet: View {
    @ObservedObject var center: DoorApprovals
    let approval: DoorApproval

    private var title: String { DoorApprovals.titles[approval.command] ?? approval.title }

    var body: some View {
        VStack(spacing: 0) {
            DoorHubView(state: .armed, compact: false)
                .frame(height: 170)
                .allowsHitTesting(false)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("\(title)?")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("\(approval.source) asked · \(approval.ageSeconds < 5 ? "just now" : "\(approval.ageSeconds) s ago")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Anyone at the door can talk to the Pod: say so where the decision is made.
                Text("Only approve if you asked Jarvis yourself.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(JcTheme.amber)
            }
            .padding(.top, 14)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, approval.deadline.timeIntervalSince(context.date))
                Text(String(format: "Answer within %d:%02d", Int(left) / 60, Int(left) % 60))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            Group {
                if let answer = center.answer {
                    VStack(spacing: 8) {
                        Image(systemName: answer.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(answer.ok ? JcTheme.success : JcTheme.danger)
                        Text(answer.text).font(.headline).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 108)
                } else {
                    VStack(spacing: 6) {
                        Button {
                            Task { await center.approve(approval) }
                        } label: {
                            HStack(spacing: 10) {
                                if center.working {
                                    ProgressView().tint(JcTheme.accent)
                                } else {
                                    Image(systemName: "faceid")
                                    Text("Approve with Face ID")
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
                        .disabled(center.working)
                        Button("Deny") { Task { await center.deny(approval) } }
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                            .buttonStyle(.plain)
                            .disabled(center.working)
                    }
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(JcTheme.bg, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: center.answer)
        .accessibilityElement(children: .contain)
    }
}
