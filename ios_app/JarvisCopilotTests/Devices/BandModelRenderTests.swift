import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// Renders the procedural HBand offscreen. With `JC_RENDER_DIR` set (pass it as
/// `TEST_RUNNER_JC_RENDER_DIR` to xcodebuild) the frames are written out, to be judged against
/// the product photo composited on the app's black background.
@MainActor
final class BandModelRenderTests: XCTestCase {

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

    /// Redraws an image into a known RGBA layout: a texture's own byte order is the renderer's choice.
    private func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    func testTheBandRendersAFrame() throws {
        let live = BandModel.Live(spin: false)
        let image = try render(live.scene, live.camera)
        XCTAssertEqual(image.size.width, 720)
        // Something was drawn: the frame is not empty.
        let (bytes, width, height) = try pixels(image)
        let covered = stride(from: 3, to: width * height * 4, by: 4).filter { bytes[$0] > 0 }.count
        XCTAssertGreaterThan(covered, width * height / 20)
        write(image, "band-render.png")
    }

    /// The photo's pose, then the pod face-on, the marked rail, the back of the loop, the
    /// sensor window inside, edge-on and from above; and a close look at the pod and the weave.
    func testTheBandFromEverySide() throws {
        for (angle, name) in [(BandModel.defaultAngle, "band-photo-pose.png"), (Float(0), "band-front.png"),
                              (.pi / 2, "band-side.png"), (.pi, "band-back.png"), (-.pi / 2, "band-other-side.png"),
                              (.pi * 0.8, "band-inside.png")] {
            let live = BandModel.Live(spin: false, spinAngle: angle)
            write(try render(live.scene, live.camera), name)
        }
        let flat = BandModel.Live(spin: false, tilt: 0.0, cameraDistance: 4.8)
        write(try render(flat.scene, flat.camera), "band-level.png")
        let top = BandModel.Live(spin: false, tilt: 1.35, cameraDistance: 4.8)
        write(try render(top.scene, top.camera), "band-top-down.png")
        let close = BandModel.Live(spin: false, cameraDistance: 2.6)
        write(try render(close.scene, close.camera, size: 1024), "band-close.png")
    }

    /// The Devices thumbnail, as `WearableModelView` frames it.
    func testTheThumbnailRenders() throws {
        let live = BandModel.Live(spin: false, cameraDistance: 5.6)
        let image = try render(live.scene, live.camera, size: 168)
        XCTAssertEqual(image.size.width, 168)
        write(image, "band-thumbnail.png")
    }

    /// The weave is near-black, has real texture in it, and tiles: its opposite edges run on
    /// into each other as smoothly as any two neighbouring columns do.
    func testTheWeaveIsDarkTexturedAndSeamless() throws {
        let (bytes, width, height) = try pixels(BandModel.fabric.color)
        var sum = 0.0, squares = 0.0, seam = 0.0, inside = 0.0
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let v = Double(bytes[row + x * 4])
                sum += v
                squares += v * v
                // The step to the next column; from the last column, round the wrap to the first.
                let step = abs(v - Double(bytes[row + (x + 1) % width * 4]))
                if x == width - 1 { seam += step } else { inside += step }
            }
        }
        let count = Double(width * height)
        let mean = sum / count, spread = (squares / count - mean * mean).squareRoot()
        XCTAssertLessThan(mean, 50, "the strap is black")
        XCTAssertGreaterThan(spread, 2, "the weave shows")
        XCTAssertLessThan(seam / Double(height), 2 * inside / Double(height * (width - 1)),
                          "the tile repeats without a seam")
    }
}
