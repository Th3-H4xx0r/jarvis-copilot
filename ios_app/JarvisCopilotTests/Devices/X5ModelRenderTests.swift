import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// Renders the procedural X5 offscreen. With `JC_RENDER_DIR` set (pass it as
/// `TEST_RUNNER_JC_RENDER_DIR` to xcodebuild) the frames are written out, to be judged against
/// photographs of the real ring composited on the app's black background.
@MainActor
final class X5ModelRenderTests: XCTestCase {

    private func render(_ scene: SCNScene, _ camera: SCNNode, size: CGFloat = 720) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"],
              let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    func testTheX5RendersAFrame() throws {
        let live = X5Model.Live(spin: false)
        let image = try render(live.scene, live.camera)
        XCTAssertEqual(image.size.width, 720)
        write(image, "x5-render.png")
    }

    /// The touch target facing the camera, the inside through the opening, and the side.
    func testTheX5FromEverySide() throws {
        for (angle, name) in [(Float(0), "x5-front.png"), (.pi / 2, "x5-side.png"), (.pi, "x5-back.png")] {
            let live = X5Model.Live(spin: false, spinAngle: angle)
            write(try render(live.scene, live.camera), name)
        }
        let flat = X5Model.Live(spin: false, tilt: 0.05, cameraDistance: 4.6)
        write(try render(flat.scene, flat.camera), "x5-edge-on.png")
        let top = X5Model.Live(spin: false, tilt: 1.45, cameraDistance: 4.6)
        write(try render(top.scene, top.camera), "x5-top-down.png")
    }

    /// The Mac menubar's picture of the X5, shipped with the desktop client.
    func testTheMacMenuIconRenders() throws {
        let live = X5Model.Live(spin: false, tilt: 0.95, cameraDistance: 4.1)
        let image = try render(live.scene, live.camera, size: 144)
        XCTAssertEqual(image.size.width, 144)
        write(image, "icon-x5ring.png")
    }

    /// The four white arcs of the touch target, on the black band — read straight off the texture.
    func testTheTouchTargetIsWhiteArcsOnTheBlackBand() throws {
        let face = X5Model.outerFace
        guard let cg = face.color.cgImage else { return XCTFail("no texture") }
        let width = cg.width, height = cg.height
        // Redraw into a known RGBA layout: the texture's own byte order is the renderer's choice.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func brightness(u: Double, v: Double) -> Int {
            // A bitmap context's first row in memory is the image's top row, as v counts.
            let x = min(width - 1, Int(u * Double(width))), y = min(height - 1, Int(v * Double(height)))
            let i = (y * width + x) * 4
            return (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        }
        let centre = X5Model.touchTargetU
        // Band away from the target: near black.
        XCTAssertLessThan(brightness(u: centre + 0.2, v: 0.5), 40)
        // The ring's top, on the arc: white.
        let radiusU = X5Model.touchTargetRadius / X5Model.circumference
        XCTAssertGreaterThan(brightness(u: centre, v: 0.5 - X5Model.touchTargetRadius / X5Model.bandWidth), 150)
        // Its centre: the black band again.
        XCTAssertLessThan(brightness(u: centre, v: 0.5), 40)
        XCTAssertGreaterThan(radiusU, 0)
    }
}
