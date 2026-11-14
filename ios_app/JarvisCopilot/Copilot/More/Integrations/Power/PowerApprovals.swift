import SwiftUI

/// Face ID approvals for Power integrations: switching a protected one off (asked from
/// this phone, the web, the Mac or by Jarvis) and settings Jarvis may change only with
/// Face ID. The server binds the change to the approval; this phone signs
/// `jarvis-power|<command>|<id>|<ts>`.
struct PowerApprovalDomain: FaceIDApprovalDomain {
    var api: JarvisAPI { .shared }
    var prefix: String { PowerAPI.prefix }
    var signingDomain: String { "jarvis-power" }

    /// `off:<id>` / `settings:<id>:<digest>`, in the app's own words with the name it knows.
    func title(for approval: FaceIDApproval) -> String? {
        let parts = approval.command.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        let name = PowerState.shared.row(parts[1])?.name ?? parts[1]
        switch parts[0] {
        case "off": return "Switch off \(name)"
        case "settings": return "Change \(name) settings"
        default: return nil
        }
    }

    func tint(for approval: FaceIDApproval) -> Color {
        approval.command.hasPrefix("off:") ? JcTheme.danger : JcTheme.accent
    }

    var warning: String? { "Approve only if you asked for this." }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        let o = try await api.post(prefix + "/approvals/\(approval.id)/approve",
                                   json: ["ts": proof.ts, "signature": proof.signature], timeout: 60).object()
        await PowerState.shared.refresh()
        let ok = o["ok"] as? Bool ?? true
        return FaceIDApprovals.Answer(text: ok ? "Done" : (o["error"] as? String ?? "That didn't work"), ok: ok)
    }

    func answered() async { await PowerState.shared.refresh() }

    func hero(for approval: FaceIDApproval) -> AnyView {
        let parts = approval.command.split(separator: ":").map(String.init)
        let id = parts.count >= 2 ? parts[1] : ""
        let icon = PowerState.shared.row(id)?.icon ?? "bolt.fill"
        return AnyView(
            VStack(spacing: 10) {
                JcIcon(icon, size: 44)
                    .foregroundStyle(JcTheme.text)
                    .frame(width: 96, height: 96)
                    .background(JcButton.fill, in: Circle())
                // What a settings change sets ("Alerts per hour at most → 0"), so he
                // approves exactly what was asked.
                if let detail = approval.detail {
                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(JcTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 12)
        )
    }
}

enum PowerApprovals {
    /// The server calls this after asking for a Power approval: brings up the Face ID card.
    static func skill() -> any LocalSkill {
        AnySkill(name: "power_show_approvals",
                 description: "Bring up waiting Power integration changes for Face ID on his iPhone. "
                    + "The server calls this itself after power_set; you don't need to.") { _ in
            Task { await FaceIDApprovals.power.refresh() }
            return ["ok": true]
        }
    }
}
