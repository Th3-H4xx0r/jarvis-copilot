import SwiftUI
import UIKit

/// A request Jarvis made that only Face ID on this iPhone can approve.
struct FaceIDApproval: Identifiable, Equatable, Sendable {
    let id: String
    let command: String
    let title: String
    let source: String
    let ageSeconds: Int
    let expiresInSeconds: Int
    /// What the request covers, content-free ("3 items, including a folder") — the vault's.
    var detail: String? = nil
    /// When this copy came from the server: the countdown runs from here.
    let receivedAt: Date

    /// When the server stops accepting an answer.
    var deadline: Date { receivedAt.addingTimeInterval(TimeInterval(expiresInSeconds)) }

    init?(json o: [String: Any], receivedAt: Date = Date()) {
        guard let id = o["id"] as? String, let command = o["command"] as? String else { return nil }
        self.id = id
        self.command = command
        title = o["title"] as? String ?? command
        source = o["source"] as? String ?? "Jarvis"
        ageSeconds = (o["age_s"] as? NSNumber)?.intValue ?? 0
        expiresInSeconds = (o["expires_in_s"] as? NSNumber)?.intValue ?? 120
        detail = (o["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.receivedAt = receivedAt
    }
}

/// What one kind of approval (the car's commands, the door alarm's) brings to the shared card.
/// The server side is the same for both: `<prefix>/approvals`, `/approve`, `/deny`.
@MainActor
protocol FaceIDApprovalDomain {
    var api: JarvisAPI { get }
    /// `/api/car`, `/api/door`.
    var prefix: String { get }
    /// Keeps one domain's signatures from being accepted as another's (`jarvis-car`, `jarvis-home`).
    var signingDomain: String { get }
    /// The action in the app's own words — never whatever text a server sent. Nil for an action
    /// this app doesn't approve.
    func title(for approval: FaceIDApproval) -> String?
    /// Sends the signed approval; what to show for it.
    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer
    /// After an answer has shown.
    func answered() async

    func tint(for approval: FaceIDApproval) -> Color
    /// What the card shows above the question.
    func hero(for approval: FaceIDApproval) -> AnyView
    /// A line under the question, when the request could have come from someone else.
    var warning: String? { get }
}

extension FaceIDApprovalDomain {
    func answered() async {}
    func tint(for approval: FaceIDApproval) -> Color { JcTheme.accent }
    var warning: String? { nil }
}

/// Approvals waiting for Face ID on this iPhone. Checked when the app comes forward (a tapped
/// approval notification lands here) and whenever the server calls the domain's
/// `*_show_approvals`. Shown on a card in its own window, above any sheet already up.
@MainActor
final class FaceIDApprovals: ObservableObject {
    static let car = FaceIDApprovals(domain: CarApprovalDomain())
    static let door = FaceIDApprovals(domain: DoorApprovalDomain())
    static let vault = FaceIDApprovals(domain: VaultApprovalDomain())

    struct Answer: Equatable {
        let text: String
        let ok: Bool
    }

    @Published private(set) var pending: [FaceIDApproval] = []
    /// The approval on the card — kept while its answer shows, after it has left `pending`.
    @Published private(set) var current: FaceIDApproval?
    @Published private(set) var working = false
    @Published private(set) var answer: Answer?

    let domain: FaceIDApprovalDomain
    let approver: ToyotaApprover
    private var active = false
    private let window = OverlayWindow()
    private var expiry: Task<Void, Never>?

    init(domain: FaceIDApprovalDomain, approver: ToyotaApprover? = nil) {
        self.domain = domain
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
        guard domain.api.isPaired else { return }
        do {
            let o = try await domain.api.get(domain.prefix + "/approvals", timeout: 20).object()
            pending = (o["approvals"] as? [[String: Any]] ?? []).compactMap { FaceIDApproval(json: $0) }
        } catch {
            if wasCancelled(error) { return }
        }
        if !working, answer == nil { show(pending.first) }
        updateWindow()
    }

    func approve(_ approval: FaceIDApproval) async {
        guard !working else { return }
        guard let title = domain.title(for: approval) else {
            await finish(approval, Answer(text: "Jarvis asked for something this app doesn't approve.", ok: false))
            return
        }
        working = true
        let result: Answer
        do {
            let proof = try await approver.proof(for: approval.command, title: title, nonce: approval.id,
                                                 domain: domain.signingDomain)
            result = try await domain.approve(approval, proof: proof)
        } catch CarSignError.cancelled {
            working = false   // still waiting: he can try again or deny
            return
        } catch {
            if case .http(403, _)? = error as? APIError { approver.forgetRegistration() }
            result = Answer(text: apiErrorMessage(error), ok: false)
        }
        // Answered either way (the server ended it): show the answer, then move on.
        await finish(approval, result)
        await domain.answered()
        await refresh()
    }

    func deny(_ approval: FaceIDApproval) async {
        guard !working else { return }
        working = true
        _ = try? await domain.api.post(domain.prefix + "/approvals/\(approval.id)/deny")
        pending.removeAll { $0.id == approval.id }
        working = false
        show(pending.first)
        updateWindow()
    }

    private func finish(_ approval: FaceIDApproval, _ result: Answer) async {
        answer = result
        pending.removeAll { $0.id == approval.id }
        working = false
        try? await Task.sleep(for: .seconds(1.8))
        answer = nil
        show(pending.first)
        updateWindow()
    }

    /// Puts an approval on the card and takes it off again when the server's time runs out.
    private func show(_ approval: FaceIDApproval?) {
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
        if active, current != nil { window.show { FaceIDApprovalCard(center: self) } } else { window.hide() }
    }
}

/// "Lock the car?" over everything: the domain's picture above the question, the time left to
/// answer, Approve with Face ID — and Deny, quietly, underneath. The app's black glass card and
/// glass buttons, no gradients.
struct FaceIDApprovalCard: View {
    @ObservedObject var center: FaceIDApprovals

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6).ignoresSafeArea()
            if let approval = center.current {
                ApprovalSheet(center: center, approval: approval)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.current?.id)
    }
}

private struct ApprovalSheet: View {
    @ObservedObject var center: FaceIDApprovals
    let approval: FaceIDApproval

    private var tint: Color { center.domain.tint(for: approval) }
    private var title: String { center.domain.title(for: approval) ?? approval.title }

    var body: some View {
        VStack(spacing: 0) {
            center.domain.hero(for: approval)

            VStack(spacing: 6) {
                Text("\(title)?")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("\(approval.source) asked · \(asked)")
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
                if let warning = center.domain.warning {
                    Text(warning)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(JcTheme.amber)
                }
            }
            .padding(.top, 14)

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
        .background(JcTheme.bg, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: center.answer)
        .accessibilityElement(children: .contain)
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
                    .foregroundStyle(JcTheme.muted)
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
                        JcLoader().foregroundStyle(tint)
                    } else {
                        Image(systemName: "faceid")
                        Text("Approve with Face ID")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.jcGlass(tint: tint, full: true))
            .disabled(center.working)

            Button("Deny") { Task { await center.deny(approval) } }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(center.working)
        }
    }

    private func answerView(_ answer: FaceIDApprovals.Answer) -> some View {
        VStack(spacing: 8) {
            Image(systemName: answer.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(answer.ok ? JcTheme.success : JcTheme.danger)
                .symbolEffect(.bounce, value: answer)
                .transition(.scale.combined(with: .opacity))
            Text(answer.text)
                .font(JcText.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(answer.ok ? Color.primary : JcTheme.danger)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .accessibilityElement(children: .combine)
    }
}
