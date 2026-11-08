import SwiftUI

/// Disarm / silence requests Jarvis made, on the shared Face ID approval card.
struct DoorApprovalDomain: FaceIDApprovalDomain {
    var door = DoorAlarmAPI()

    /// The only actions this app signs, in its own words.
    static let titles = ["disarm": "Disarm the door alarm", "silence": "Silence the siren"]

    var api: JarvisAPI { door.api }
    var prefix: String { DoorAlarmAPI.prefix }
    var signingDomain: String { DoorAlarmAPI.domain }
    // Anyone at the door can talk to the Pod: say so where the decision is made.
    var warning: String? { "Only approve if you asked Jarvis yourself." }

    func title(for approval: FaceIDApproval) -> String? { Self.titles[approval.command] }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        let state = try await door.approve(approval, proof: proof)
        let disarm = approval.command == "disarm"
        return FaceIDApprovals.Answer(text: disarm ? "Disarmed" : "Siren silenced",
                                      ok: state.alarm.state == "disarmed" || !disarm)
    }

    func answered() async { await DoorAlarmStore.shared.load() }

    func hero(for approval: FaceIDApproval) -> AnyView {
        AnyView(DoorHubView(state: .armed, compact: false)
            .frame(height: 170)
            .allowsHitTesting(false)
            .padding(.top, 8))
    }
}
