import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Wearables cards show their models as still pictures: one frame drawn offscreen, no
/// `SCNView` left turning behind every tab. The device's own screen keeps the live model.
@MainActor
final class SceneStillTests: XCTestCase {
    func testAStillIsTransparentAroundTheModelAndDrawnInTheMiddle() async throws {
        let live = BandModel.Live(spin: true, tilt: BandModel.defaultTilt, cameraDistance: 5.6, spinSeconds: 34)
        let shot = await SceneStillRenderer.image(scene: live.scene, camera: live.camera,
                                                  size: CGSize(width: 124, height: 124), scale: 2)
        let image = try XCTUnwrap(shot)
        XCTAssertEqual(image.size, CGSize(width: 124, height: 124))
        let pixels = try XCTUnwrap(Pixels(image))
        XCTAssertEqual(pixels.alpha(x: 1, y: 1), 0, "the corner shows what is behind the card")
        XCTAssertGreaterThan(pixels.opaqueShare(inCentre: 0.5), 0.05, "the model is drawn")
    }

    func testACardInStillsModeHasNoSceneViewAndALiveOneDoes() throws {
        XCTAssertEqual(try sceneViews(in: BandSceneView(spin: true, cameraDistance: 5.6)
            .environment(\.sceneStills, true)), 0)
        XCTAssertEqual(try sceneViews(in: BandSceneView(spin: true, cameraDistance: 5.6)), 1)
    }

    /// Looked at, not guessed: the stills and the live models, side by side in /tmp/ringshots.
    func testRendersTheWearableStillsForALook() throws {
        let size = CGSize(width: 124, height: 124)
        try RenderHarness.write(BandSceneView(spin: true, cameraDistance: 5.6).environment(\.sceneStills, true),
                                size: size, name: "still-band")
        try RenderHarness.write(X5SceneView(spin: true, tilt: 1.0, cameraDistance: 5.6, spinSeconds: 44)
            .environment(\.sceneStills, true), size: size, name: "still-x5")
        try RenderHarness.write(GlassesSceneView(spin: true, lit: true).environment(\.sceneStills, true),
                                size: size, name: "still-glasses-lit")
        try RenderHarness.write(DoorHubView(state: .armed).environment(\.sceneStills, true),
                                size: CGSize(width: 210, height: 150), name: "still-door-armed")
        try RenderHarness.write(CarSceneView(presentation: .card, lit: true).environment(\.sceneStills, true),
                                size: CGSize(width: 262, height: 150), name: "still-car-lit", settle: 4)
    }

    private func sceneViews(in view: some View) throws -> Int {
        let host = UIHostingController(rootView: view.frame(width: 124, height: 124))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 124, height: 124))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        defer { window.isHidden = true }
        func count(_ view: UIView) -> Int { (view is SCNView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) } }
        return count(window)
    }
}

/// An image's pixels as RGBA bytes, to read its alpha.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        bytes = data
    }

    func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    /// The share of pixels with any alpha in the middle `fraction` of the image.
    func opaqueShare(inCentre fraction: Double) -> Double {
        let x0 = Int(Double(width) * (1 - fraction) / 2), y0 = Int(Double(height) * (1 - fraction) / 2)
        let x1 = width - x0, y1 = height - y0
        var lit = 0
        for y in y0..<y1 { for x in x0..<x1 where alpha(x: x, y: y) > 0 { lit += 1 } }
        return Double(lit) / Double((x1 - x0) * (y1 - y0))
    }
}
