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

/// "Lock the car?" over everything: the car itself turning above the question, the action's badge,
/// the time left to answer, Approve with Face ID — and Deny, quietly, underneath.
struct CarApprovalCard: View {
    @ObservedObject var center: CarApprovals

    var body: some View {
        ZStack(alignment: .bottom) {
            // The app stays visible behind, softened — a request on top of it, not a new screen.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()
            if let approval = center.current {
                ApprovalSheet(center: center, approval: approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.current?.id)
    }
}

private struct ApprovalSheet: View {
    @ObservedObject var center: CarApprovals
    let approval: CarApproval

    private var command: ToyotaCommand? { ToyotaCommand(rawValue: approval.command) }
    /// Opening or starting the car reads amber; everything else in the app's accent.
    private var tint: Color {
        switch command {
        case .unlock?, .trunkUnlock?, .start?: return JcTheme.amber
        default: return JcTheme.accent
        }
    }
    /// The lamps glow for the commands that work the lights.
    private var lit: Bool { [.lights, .hazardsOn, .hazardsOff].contains(command) }
    private var title: String { command?.approvalTitle ?? approval.title }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                // A soft pool of the action's colour under the car — blurred, so it has no edges.
                Ellipse()
                    .fill(tint.opacity(0.32))
                    .frame(width: 300, height: 90)
                    .blur(radius: 38)
                    .offset(y: -18)
                if CarModel.hasBundledModel {
                    CarSceneView(presentation: .hero, lit: lit, spinSeconds: 36, animatesAnywhere: true)
                        .frame(height: 210)
                        .allowsHitTesting(false)
                }
                badge.offset(y: 26)
            }
            .frame(height: 210)
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text("\(title)?")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("\(approval.source) asked · \(asked)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)

            countdown.padding(.top, 16)

            Group {
                if let answer = center.answer {
                    answerView(answer)
                } else {
                    actions
                }
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(JcTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: center.answer)
        .accessibilityElement(children: .contain)
    }

    private var badge: some View {
        JcIcon(command?.symbol ?? "car.fill", size: 22)
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .jcLiquidGlass(in: Circle(), tint: tint.opacity(0.25))
            .overlay(Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var asked: String {
        approval.ageSeconds < 5 ? "just now" : "\(approval.ageSeconds) s ago"
    }

    /// The time left to answer: a thin bar that empties, and m:ss beside it.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, approval.deadline.timeIntervalSince(context.date))
            let total = max(1, Double(approval.expiresInSeconds + approval.ageSeconds))
            HStack(spacing: 10) {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.85))
                                .frame(width: geo.size.width * min(1, left / total))
                                .animation(.linear(duration: 1), value: left)
                        }
                }
                .frame(height: 4)
                Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time left")
            .accessibilityValue("\(Int(left)) seconds")
        }
        .padding(.horizontal, 6)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                Task { await center.approve(approval) }
            } label: {
                HStack(spacing: 10) {
                    if center.working {
                        ProgressView().tint(tint)
                    } else {
                        Image(systemName: "faceid").font(.system(size: 20, weight: .semibold))
                        Text("Approve with Face ID").font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 58)
                .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: tint.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
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

    private func answerView(_ answer: CarApprovals.Answer) -> some View {
        VStack(spacing: 8) {
            Image(systemName: answer.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(answer.ok ? JcTheme.success : JcTheme.danger)
                .symbolEffect(.bounce, value: answer)
                .transition(.scale.combined(with: .opacity))
            Text(answer.text)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(answer.ok ? Color.primary : JcTheme.danger)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .accessibilityElement(children: .combine)
    }
}
