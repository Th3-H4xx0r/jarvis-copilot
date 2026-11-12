import SwiftUI

/// Jarvis's vault requests (search, read, save, move, delete) on the shared Face ID approval
/// card: each one runs only after Face ID signs that exact request on this iPhone.
struct VaultApprovalDomain: FaceIDApprovalDomain {
    var api: JarvisAPI { .shared }
    var prefix: String { VaultAPI.prefix }
    var signingDomain: String { VaultAPI.signingDomain }

    /// The only actions this app signs, in its own words — never text the server sent.
    static let titles = [
        "search": "Let Jarvis search your vault",
        "list": "Let Jarvis look in a vault folder",
        "read": "Let Jarvis read a vault item",
        "save": "Let Jarvis save to your vault",
        "move": "Let Jarvis move vault items",
        "delete": "Let Jarvis delete vault items",
    ]

    func title(for approval: FaceIDApproval) -> String? { Self.titles[approval.command] }

    func tint(for approval: FaceIDApproval) -> Color {
        approval.command == "delete" ? JcTheme.danger : JcTheme.accent
    }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        let o = try await api.post(prefix + "/approvals/\(approval.id)/approve",
                                   json: ["ts": proof.ts, "signature": proof.signature], timeout: 60).object()
        VaultSession.shared.changed()
        let ok = o["ok"] as? Bool ?? true
        let summary = (o["result_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return FaceIDApprovals.Answer(text: summary ?? (ok ? "Approved" : "That didn't work"), ok: ok)
    }

    func hero(for approval: FaceIDApproval) -> AnyView {
        AnyView(
            VStack(spacing: 10) {
                JcIcon("lock.fill", size: 44)
                    .foregroundStyle(JcTheme.text)
                    .frame(width: 96, height: 96)
                    .background(JcButton.fill, in: Circle())
                if let detail = approval.detail {
                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(approval.command == "delete" ? JcTheme.danger : JcTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 12)
        )
    }
}

enum VaultApprovals {
    /// The server calls this after Jarvis asks to use the vault: brings up the Face ID card.
    static func skill() -> any LocalSkill {
        AnySkill(name: "vault_show_approvals",
                 description: "Bring up Jarvis's waiting vault requests for Face ID on his iPhone. "
                    + "The server calls this itself after a vault_* tool; you don't need to.") { _ in
            Task { await FaceIDApprovals.vault.refresh() }
            return ["ok": true]
        }
    }
}
