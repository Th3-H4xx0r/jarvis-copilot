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
