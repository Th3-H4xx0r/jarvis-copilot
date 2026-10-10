import SwiftUI
import UIKit

/// Car commands Jarvis asked for, waiting for Face ID on this iPhone. Checked when the app comes
/// forward (a tapped approval notification lands here) and whenever the server calls the car's
/// `car_show_approvals`. Shown on a card in its own window, above any sheet already up.
@MainActor
final class CarApprovals: ObservableObject {
    static let shared = CarApprovals()

    struct Answer: Equatable {
        let text: String
        let ok: Bool
    }

    @Published private(set) var pending: [CarApproval] = []
    /// The approval on the card — kept while its answer shows, after it has left `pending`.
    @Published private(set) var current: CarApproval?
    @Published private(set) var working = false
    @Published private(set) var answer: Answer?

    let api: ToyotaAPI
    let approver: ToyotaApprover
    private var active = false
    private var window: UIWindow?
    private var expiry: Task<Void, Never>?

    init(api: ToyotaAPI = ToyotaAPI(), approver: ToyotaApprover? = nil) {
        self.api = api
        self.approver = approver ?? ToyotaApprover.shared
    }

    /// Follows the app's scene phase. The Face ID prompt makes the app `.inactive` for a moment —
    /// the card must stay up through it, so only `.background` puts it away.
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

    func approve(_ approval: CarApproval) async {
        guard !working else { return }
        // Only a command this app knows (and gates), described in the app's own words — never sign
        // whatever text a server sent.
        guard let command = ToyotaCommand(rawValue: approval.command), command.needsFaceID else {
            answer = Answer(text: "Jarvis asked for something this app doesn't approve.", ok: false)
            pending.removeAll { $0.id == approval.id }
            try? await Task.sleep(for: .seconds(1.8))
            answer = nil
            show(pending.first)
            updateWindow()
            return
        }
        working = true
        do {
            let proof = try await approver.proof(for: command.rawValue, title: command.approvalTitle, nonce: approval.id)
            answer = Answer(text: try await api.approve(approval, proof: proof), ok: true)
        } catch CarSignError.cancelled {
            working = false   // still waiting: he can try again or deny
            return
        } catch {
            if case .http(403, _) = error as? APIError { approver.forgetRegistration() }
            answer = Answer(text: apiErrorMessage(error), ok: false)
        }
        // Answered either way (the server ended it): show the answer, then move on.
        pending.removeAll { $0.id == approval.id }
        working = false
        try? await Task.sleep(for: .seconds(1.8))
        answer = nil
        show(pending.first)
        updateWindow()
        await refresh()
    }

    func deny(_ approval: CarApproval) async {
        guard !working else { return }
        working = true
        do {
            try await api.deny(approval)
        } catch {
            if !wasCancelled(error) { _ = apiErrorMessage(error) }
        }
        pending.removeAll { $0.id == approval.id }
        working = false
        show(pending.first)
        updateWindow()
    }

    /// Puts an approval on the card and takes it off again when the server's two minutes run out.
    private func show(_ approval: CarApproval?) {
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

    // MARK: Window

    private func updateWindow() {
        if active, current != nil { show() } else { hide() }
    }

    private func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: CarApprovalCard(center: self))
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

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// "Unlock the car?" — Approve with Face ID or Deny, over everything.
struct CarApprovalCard: View {
    @ObservedObject var center: CarApprovals

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5).ignoresSafeArea()
            if let approval = center.current {
                card(approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: center.current)
        .animation(.easeInOut(duration: 0.2), value: center.answer)
    }

    private func card(_ approval: CarApproval) -> some View {
        VStack(spacing: 14) {
            JcIcon("car.fill", size: 24)
                .foregroundStyle(JcTheme.accent)
                .frame(width: 58, height: 58)
                .background(JcTheme.accent.opacity(0.15), in: Circle())
            Text("\(ToyotaCommand(rawValue: approval.command)?.approvalTitle ?? approval.title)?")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Asked by \(approval.source) · \(age(approval))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let answer = center.answer {
                Label(answer.text, systemImage: answer.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(answer.ok ? JcTheme.success : JcTheme.danger)
                    .padding(.vertical, 8)
            } else {
                Button {
                    Task { await center.approve(approval) }
                } label: {
                    if center.working {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Approve with Face ID", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.jcGlass(full: true))
                .disabled(center.working)
                Button("Deny") { Task { await center.deny(approval) } }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                    .disabled(center.working)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func age(_ approval: CarApproval) -> String {
        approval.ageSeconds < 5 ? "just now" : "\(approval.ageSeconds) s ago"
    }
}
