import SwiftUI

/// Car commands Jarvis asked for, on the shared Face ID approval card.
struct CarApprovalDomain: FaceIDApprovalDomain {
    var toyota = ToyotaAPI()

    var api: JarvisAPI { toyota.api }
    var prefix: String { ToyotaAPI.prefix }
    var signingDomain: String { "jarvis-car" }

    func title(for approval: FaceIDApproval) -> String? {
        guard let command = ToyotaCommand(rawValue: approval.command), command.needsFaceID else { return nil }
        return command.approvalTitle
    }

    func approve(_ approval: FaceIDApproval, proof: ToyotaApprover.Proof) async throws -> FaceIDApprovals.Answer {
        FaceIDApprovals.Answer(text: try await toyota.approve(approval, proof: proof), ok: true)
    }

    /// Opening or starting the car reads amber; everything else in the app's accent.
    func tint(for approval: FaceIDApproval) -> Color {
        switch ToyotaCommand(rawValue: approval.command) {
        case .unlock?, .trunkUnlock?, .start?: return JcTheme.amber
        default: return JcTheme.accent
        }
    }

    /// The car itself, still, with the action's badge over its foot.
    func hero(for approval: FaceIDApproval) -> AnyView {
        let command = ToyotaCommand(rawValue: approval.command)
        // The lamps glow for the commands that work the lights.
        let lit = [.lights, .hazardsOn, .hazardsOff].contains(command)
        return AnyView(
            ZStack(alignment: .bottom) {
                if CarModel.hasBundledModel {
                    // Turns in from nearly head-on to a mostly side-on pose, centred, and stays.
                    CarSceneView(presentation: .approval, spin: false, lit: lit, turnsIntoPlace: true)
                        .frame(height: 200)
                        .allowsHitTesting(false)
                }
                JcIcon(command?.symbol ?? "car.fill", size: 22)
                    .foregroundStyle(tint(for: approval))
                    .frame(width: 56, height: 56)
                    .jcButtonSurface(in: Circle())
                    .accessibilityHidden(true)
                    .offset(y: 26)
            }
            .frame(height: 200)
            .padding(.top, 10)
            .padding(.bottom, 26))
    }
}
