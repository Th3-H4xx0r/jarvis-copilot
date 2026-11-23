import SwiftUI

/// Force restart / force off of his Windows PC (2026-11-23) through the ESP32 wired to its front-panel
/// header: reset pressed for 300 ms, or power held for 6 s. Only ever after Face ID on this iPhone —
/// tapped on the card (approved at once) or asked for on the web / by Jarvis (this card). The server
/// checks the signature (`jarvis-pc-power|<command>|<id>|<ts>`) itself, since a frozen PC can't.
/// Server side: webui/api/pc_power.py.
struct PcPowerApprovalDomain: FaceIDApprovalDomain {
    var api: JarvisAPI { .shared }
    var prefix: String { "/api/pc-power" }
    var signingDomain: String { "jarvis-pc-power" }

    /// The app's own words, never the server's text; nil for anything but the two force commands.
    func title(for approval: FaceIDApproval) -> String? { PcPowerCopy.title(command: approval.command) }

    var warning: String? { "Only for a frozen PC: anything unsaved on it is lost." }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        let o = try await api.post(prefix + "/approvals/\(approval.id)/approve",
                                   json: ["ts": proof.ts, "signature": proof.signature], timeout: 30).object()
        return PcPowerCopy.answer(command: approval.command, reply: o)
    }

    func hero(for approval: FaceIDApproval) -> AnyView {
        AnyView(
            Image(systemName: approval.command == "force_off" ? "power" : "arrow.clockwise")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(JcTheme.text)
                .frame(width: 96, height: 96)
                .background(JcButton.fill, in: Circle())
                .padding(.top, 12)
                .accessibilityHidden(true)
        )
    }
}

enum PcPowerCopy {
    static func title(command: String) -> String? {
        switch command {
        case "force_restart": return "Force restart your PC"
        case "force_off": return "Force off your PC"
        default: return nil
        }
    }

    /// The approve route's `{ok, result}` (result = the board's press: `{ok, light_before}` or
    /// `{ok: false, error}`), in words.
    static func answer(command: String, reply o: [String: Any]) -> FaceIDApprovals.Answer {
        let result = o["result"] as? [String: Any] ?? [:]
        let ok = (o["ok"] as? Bool ?? true) && (result["ok"] as? Bool ?? true)
        guard ok else {
            let why = (o["error"] as? String) ?? (result["error"] as? String)
            return FaceIDApprovals.Answer(text: why.flatMap { $0.isEmpty ? nil : $0 } ?? "That didn't work", ok: false)
        }
        return FaceIDApprovals.Answer(text: command == "force_off" ? "Holding the power button for 6 seconds"
                                                                   : "Pressed reset · your PC is restarting",
                                      ok: true)
    }
}

enum PcPowerApprovals {
    /// The server can call this after the web or Jarvis asks for a force action: brings up the Face ID card.
    static func skill() -> any LocalSkill {
        AnySkill(name: "pc_power_show_approvals",
                 description: "Bring up waiting force restart / force off requests for his PC for Face ID on his iPhone. "
                    + "The server calls this itself; you don't need to.") { _ in
            Task { await FaceIDApprovals.pcPower.refresh() }
            return ["ok": true]
        }
    }
}
