import SwiftUI

/// "Run as admin on the PC" (Windows client, 2026-11-15): the PC asks, Face ID on this
/// iPhone approves (signed `jarvis-pc|run-as-admin|<id>|<ts>`, checked by the server), and
/// Windows still shows its own UAC prompt at the PC. Server side: webui/api/pc_admin.py.
struct PcAdminApprovalDomain: FaceIDApprovalDomain {
    static let command = "run-as-admin"

    var api: JarvisAPI { .shared }
    var prefix: String { "/api/pc-admin" }
    var signingDomain: String { "jarvis-pc" }

    /// The app's own words: the server's title is only used for the PC's name it carries.
    func title(for approval: FaceIDApproval) -> String? {
        guard approval.command == Self.command else { return nil }
        return PcAdminCopy.title(source: approval.source)
    }

    func tint(for approval: FaceIDApproval) -> Color { JcTheme.amber }

    var warning: String? { "Approve only if you asked for this. Windows will still ask at the PC." }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        let o = try await api.post(prefix + "/approvals/\(approval.id)/approve",
                                   json: ["ts": proof.ts, "signature": proof.signature], timeout: 60).object()
        let ok = o["ok"] as? Bool ?? true
        return FaceIDApprovals.Answer(text: ok ? "Approved. Confirm the Windows prompt at the PC."
                                               : (o["error"] as? String ?? "That didn't work"), ok: ok)
    }

    func hero(for approval: FaceIDApproval) -> AnyView {
        AnyView(
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(JcTheme.text)
                    .frame(width: 96, height: 96)
                    .background(JcButton.fill, in: Circle())
                // Exactly what will run, ALL of it (scrolls when long), so he approves that and
                // nothing hidden past a cut-off line.
                if let detail = approval.detail {
                    ScrollView {
                        Text(detail)
                            .font(.footnote.monospaced())
                            .foregroundStyle(JcTheme.muted)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(JcButton.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 12)
        )
    }
}

enum PcAdminCopy {
    static func title(source: String) -> String {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Jarvis" ? "Run as admin on your PC" : "Run as admin on \(name)"
    }
}

enum PcAdminApprovals {
    /// The server calls this after the PC asks: brings up the Face ID card.
    static func skill() -> any LocalSkill {
        AnySkill(name: "pc_admin_show_approvals",
                 description: "Bring up waiting run-as-admin requests from his PC for Face ID on his iPhone. "
                    + "The server calls this itself; you don't need to.") { _ in
            Task { await FaceIDApprovals.pcAdmin.refresh() }
            return ["ok": true]
        }
    }
}
