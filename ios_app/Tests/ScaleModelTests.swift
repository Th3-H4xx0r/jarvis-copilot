import Foundation
import SceneKit

@main
enum ScaleModelTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        // Break caught: a visual refactor drops a physical part visible in the ESF551
        // reference photos or makes the model's proportions obviously wrong.
        let parts = ScaleModel.makeNode()
        let nodes = parts.pivot.childNodes(passingTest: { _, _ in true })
        expect(nodes.filter { $0.name?.hasPrefix("electrode") == true }.count == 4,
               "ESF551 must have four metal electrodes")
        expect(nodes.filter { $0.name?.hasPrefix("foot") == true }.count == 4,
               "ESF551 must have four underside feet")
        expect(nodes.contains { $0.name == "glassDeck" }, "glass deck must be modeled")
        expect(nodes.contains { $0.name == "displayWindow" }, "top display window must be modeled")
        let glow = nodes.first { $0.name == "measurementGlow" }
        expect(glow?.isHidden == true, "scale must not use an emissive perimeter glow")

        let deck = nodes.first { $0.name == "glassDeck" }!
        let box = deck.geometry as? SCNBox
        expect(box != nil && abs(box!.width - box!.length) < 0.001,
               "ESF551 deck must remain square")
        expect(box != nil && box!.height < box!.width * 0.08,
               "glass deck must remain thin like the photographed scale")

        let live = ScaleModel.Live(presentation: .detail)
        expect(live.spinner.action(forKey: "turntable") == nil,
               "scale must remain still instead of running a turntable animation")
        expect(abs(live.pivot.eulerAngles.x - .pi / 2) < 0.001,
               "detail scale must begin upright and directly facing the user")
        expect(abs(parts.displayText.position.x) < 0.001,
               "scale display text must remain horizontally centered")
        expect(live.visualState == .idle, "new scale scene must start idle")
        live.setVisualState(.measuring)
        expect(live.visualState == .measuring, "scene must enter measuring state")
        expect(live.pivot.action(forKey: "pressureTilt") != nil,
               "pressure must trigger the one-time lay-down animation")
        live.setVisualState(.stable)
        expect(live.visualState == .stable, "scene must enter stable state")
    }
}
