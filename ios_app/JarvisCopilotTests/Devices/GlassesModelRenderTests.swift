import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// Renders the procedural INMO GO3 offscreen. With `JC_RENDER_DIR` set on the xcodebuild command
/// line the frames are written out, which is how the model is judged against the product photos
/// and the manual's diagram without building to a device.
@MainActor
final class GlassesModelRenderTests: XCTestCase {

    /// Two frames on scene time: the first starts any fade, the second lands after it.
    private func render(_ live: InmoGo3Model.Live, size: CGFloat = 720, height: CGFloat? = nil) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        let frame = CGSize(width: size, height: height ?? size)
        _ = renderer.snapshot(atTime: 0, with: frame, antialiasingMode: .multisampling4X)
        return renderer.snapshot(atTime: 2, with: frame, antialiasingMode: .multisampling4X)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"],
              let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// RGBA bytes, row by row from the top.
    private func pixels(of image: UIImage) -> (bytes: [UInt8], width: Int, height: Int) {
        guard let cgImage = image.cgImage else { return ([], 0, 0) }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }

    /// How much of the frame is the display's green: summed green lead over red and blue.
    private func greenness(_ image: UIImage) -> Double {
        let bytes = pixels(of: image).bytes
        return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { total, i in
            total + Double(max(0, Int(bytes[i + 1]) - max(Int(bytes[i]), Int(bytes[i + 2]))))
        }
    }

    /// Whether anything is drawn in the outermost pixels — the model clipped by the frame.
    private func touchesEdge(_ image: UIImage) -> Bool {
        let (bytes, width, height) = pixels(of: image)
        for y in 0..<height {
            for x in 0..<width where x < 2 || y < 2 || x >= width - 2 || y >= height - 2 {
                if bytes[(y * width + x) * 4 + 3] > 8 { return true }
            }
        }
        return false
    }

    func testTheCardPoseRendersLitAndUnlit() throws {
        let unlit = try render(InmoGo3Model.Live(spin: false))
        XCTAssertEqual(unlit.size.width, 720)
        write(unlit, "go3-card.png")

        let live = InmoGo3Model.Live(spin: false)
        live.setLit(true)
        let lit = try render(live)
        write(lit, "go3-card-lit.png")
        XCTAssertGreaterThan(greenness(lit), greenness(unlit) * 4 + 1000, "the display should glow green when lit")
    }

    /// The card spins: at its framing the pair must stay inside the square all the way round.
    func testTheTurntableStaysInsideTheCard() throws {
        var frames: [UIImage] = []
        for step in 0..<8 {
            let angle = 0.62 + Float(step) * .pi / 4
            let frame = try render(InmoGo3Model.Live(spin: false, spinAngle: angle), size: 240)
            XCTAssertFalse(touchesEdge(frame), "clipped at \(angle) rad")
            frames.append(frame)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = UIGraphicsImageRenderer(size: CGSize(width: 240 * 8, height: 240), format: format).image { _ in
            for (index, frame) in frames.enumerated() { frame.draw(at: CGPoint(x: index * 240, y: 0)) }
        }
        write(strip, "go3-turntable.png")
    }

    /// Straight on, from the right side, and from above — the proportions are judged on these.
    func testTheOrthogonalViewsRender() throws {
        let views: [(String, InmoGo3Model.Live)] = [
            ("go3-front.png", InmoGo3Model.Live(spin: false, tilt: 0, spinAngle: 0)),
            ("go3-side.png", InmoGo3Model.Live(spin: false, tilt: 0, spinAngle: .pi / 2)),
            ("go3-top.png", InmoGo3Model.Live(spin: false, tilt: .pi / 2, spinAngle: 0)),
            ("go3-rear.png", InmoGo3Model.Live(spin: false, spinAngle: .pi + 0.62)),
        ]
        for (name, live) in views {
            live.setLit(true)
            write(try render(live), name)
        }
    }

    /// A page hero 200 pt tall and about 360 wide. The field of view is vertical, so a wide
    /// frame takes a closer camera than the square card; the widest turn must still fit.
    func testTheHeroRenders() throws {
        let live = InmoGo3Model.Live(spin: false, cameraDistance: 3.4)
        live.setLit(true)
        write(try render(live, size: 1080, height: 600), "go3-hero-lit.png")
        for angle: Float in [1.2, 2.0, 4.1] {
            let turned = try render(InmoGo3Model.Live(spin: false, cameraDistance: 3.4, spinAngle: angle),
                                    size: 360, height: 200)
            XCTAssertFalse(touchesEdge(turned), "hero clipped at \(angle) rad")
        }
    }

    /// The small transparent icon, as the other wearables ship for the Mac menubar.
    func testTheIconRenders() throws {
        let image = try render(InmoGo3Model.Live(spin: false), size: 144)
        XCTAssertEqual(image.size.width, 144)
        write(image, "icon-glasses.png")
    }
}
