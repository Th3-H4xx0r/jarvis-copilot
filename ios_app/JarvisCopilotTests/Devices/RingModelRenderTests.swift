import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// Renders the procedural ring offscreen. With `TEST_RUNNER_JC_RENDER_DIR` set on the
/// xcodebuild command line, the frame is written as `ring-render.png` for a visual check.
@MainActor
final class RingModelRenderTests: XCTestCase {

    func testTheRingRendersAFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let live = RingModel.Live(spin: false)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 640, height: 640), antialiasingMode: .multisampling4X)

        XCTAssertEqual(image.size.width, 640)
        if let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"], let png = image.pngData() {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ring-render.png"))
        }
    }
}
