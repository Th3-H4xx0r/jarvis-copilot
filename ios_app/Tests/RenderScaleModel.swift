import AppKit
import SceneKit

@main
enum RenderScaleModel {
    static func main() throws {
        try render(state: .idle, at: 0, path: "scale-model-idle.png")
        try render(state: .measuring, at: 1.4, path: "scale-model-measuring.png")
    }

    private static func render(state: ScaleVisualState, at time: TimeInterval,
                               path: String) throws {
        let live = ScaleModel.Live(presentation: .detail)
        live.setDisplayText(state == .idle ? nil : "168.4")
        live.setVisualState(state)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 700),
                              antialiasingMode: .multisampling4X)
        let image = renderer.snapshot(atTime: time, with: CGSize(width: 900, height: 700),
                                      antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode SceneKit snapshot")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/jarvis-scale-model-tests/\(path)"))
    }
}
