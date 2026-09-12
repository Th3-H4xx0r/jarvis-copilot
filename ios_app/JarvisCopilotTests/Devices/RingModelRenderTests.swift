import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// Renders the procedural ring offscreen. With `JC_RENDER_DIR` set on the xcodebuild command
/// line the frames are written out, which is how the model is judged against photographs of the
/// real ring without building to a device.
@MainActor
final class RingModelRenderTests: XCTestCase {

    private func render(_ live: RingModel.Live, size: CGFloat = 720) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size),
                                 antialiasingMode: .multisampling4X)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"],
              let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    func testTheRingRendersAFrame() throws {
        let image = try render(RingModel.Live(spin: false))
        XCTAssertEqual(image.size.width, 720)
        write(image, "ring-render.png")
    }

    /// Small transparent renders of every wearable's 3D model, for the Mac
    /// menubar menu — which lists the devices with a picture of each, the way
    /// the system's own Bluetooth menu does. Shipped as PNGs with the desktop
    /// client rather than rendered there: the models are SceneKit scenes that
    /// only exist in this app.
    func testWearableIconsRender() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let scenes: [(String, SCNScene, SCNNode)] = [
            ("icon-ring.png", { let l = RingModel.Live(spin: false, tilt: 0.95, cameraDistance: 4.1)
                                return (l.scene, l.camera) }()),
            ("icon-bottle.png", { let l = BottleModel.Live(spin: false, tilt: -0.12, cameraZ: 3.1)
                                  return (l.scene, l.camera) }()),
            ("icon-scale.png", { let l = ScaleModel.Live(presentation: .card)
                                 return (l.scene, l.camera) }()),
        ].map { ($0.0, $0.1.0, $0.1.1) }

        let renderer = SCNRenderer(device: device, options: nil)
        for (name, scene, camera) in scenes {
            renderer.scene = scene
            renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 144, height: 144),
                                          antialiasingMode: .multisampling4X)
            XCTAssertEqual(image.size.width, 144)
            write(image, name)
        }
    }

    /// Each face of the inside, plus the profile the proportions are judged on.
    func testTheInsideRendersFromEveryAngle() throws {
        let views: [(String, RingModel.Live)] = [
            ("ring-board.png", RingModel.Live(spin: false, tilt: 1.15, cameraDistance: 4.6, spinAngle: 0)),
            ("ring-marks.png", RingModel.Live(spin: false, tilt: 1.15, cameraDistance: 4.6, spinAngle: .pi)),
            ("ring-side.png", RingModel.Live(spin: false, tilt: 0, cameraDistance: 4.4, spinAngle: 0)),
            ("ring-top.png", RingModel.Live(spin: false, tilt: .pi / 2, cameraDistance: 4.4, spinAngle: 0)),
        ]
        for (name, live) in views {
            write(try render(live), name)
        }
    }
}
