import Metal
import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders the procedural Ray-Ban Meta Scriber Optics offscreen. With JC_RENDER_DIR set (pass
/// TEST_RUNNER_JC_RENDER_DIR to xcodebuild) every frame is written out on the app's black, which is
/// how the model is judged against Ray-Ban's catalogue shots; the "-alpha" frames keep their
/// transparency so a silhouette can be laid over a photo.
@MainActor
final class MetaGlassesModelRenderTests: XCTestCase {

    /// Two frames on scene time: the first starts any fade, the second lands after it.
    private func render(_ live: MetaGlassesModel.Live, width: CGFloat = 720, height: CGFloat? = nil,
                        fieldOfView: CGFloat? = nil) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        if let fieldOfView { live.camera.camera?.fieldOfView = fieldOfView }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        let frame = CGSize(width: width, height: height ?? width)
        _ = renderer.snapshot(atTime: 0, with: frame, antialiasingMode: .multisampling4X)
        return renderer.snapshot(atTime: 2, with: frame, antialiasingMode: .multisampling4X)
    }

    /// The frame on the app's black, as the card and the page show it.
    private func onBlack(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
    }

    private func write(_ image: UIImage, _ name: String, keepAlpha: Bool = false) {
        guard let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let png = onBlack(image).pngData() {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        if keepAlpha, let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-alpha.png"))
        }
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

    /// Pixels that came up more than 40 levels from one frame to the other: a light switched on.
    private func brightened(_ lit: UIImage, over dark: UIImage) -> Int {
        let (a, b) = (pixels(of: lit).bytes, pixels(of: dark).bytes)
        guard a.count == b.count else { return 0 }
        return stride(from: 0, to: a.count, by: 4).reduce(0) { total, i in
            let gain = (Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]) - Int(b[i]) - Int(b[i + 1]) - Int(b[i + 2])) / 3
            return total + (gain > 40 ? 1 : 0)
        }
    }

    /// The columns and rows with anything drawn: the model's on-screen box.
    private func drawnBox(_ image: UIImage) -> CGRect {
        let (bytes, width, height) = pixels(of: image)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Whether anything is drawn in the outermost pixels: the model clipped by the frame.
    private func touchesEdge(_ image: UIImage) -> Bool {
        let (bytes, width, height) = pixels(of: image)
        for y in 0..<height {
            for x in 0..<width where x < 2 || y < 2 || x >= width - 2 || y >= height - 2 {
                if bytes[(y * width + x) * 4 + 3] > 8 { return true }
            }
        }
        return false
    }

    func testTheCardPoseRendersWithTheLEDOffAndOn() throws {
        let live = MetaGlassesModel.Live(spin: false)
        let off = try render(live)
        XCTAssertEqual(off.size.width, 720)
        write(off, "meta-card")

        live.setLED(true, animated: false)
        let on = try render(live)
        write(on, "meta-card-led")
        XCTAssertGreaterThan(brightened(on, over: off), 60, "the capture LED should glow white when on")

        live.setLED(false, animated: false)
        XCTAssertLessThan(brightened(try render(live), over: off), 3, "and go dark again when off")
    }

    /// Straight on, both sides, from above and the three-quarter catalogue pose: the proportions
    /// are judged on these against the product shots.
    func testTheOrthogonalViewsRender() throws {
        let views: [(String, MetaGlassesModel.Live)] = [
            ("meta-front", MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: 0)),
            ("meta-side-left", MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: -.pi / 2)),
            ("meta-side-right", MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: .pi / 2)),
            ("meta-top", MetaGlassesModel.Live(spin: false, tilt: .pi / 2, spinAngle: 0)),
            ("meta-rear", MetaGlassesModel.Live(spin: false, tilt: 0.2, spinAngle: .pi)),
            ("meta-three-quarter", MetaGlassesModel.Live(spin: false, tilt: 0.12, spinAngle: -0.62)),
        ]
        for (name, live) in views { write(try render(live), name) }
        let front = MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: 0)
        front.setLED(true, animated: false)
        write(try render(front), "meta-front-led")
    }

    /// Near-orthographic frames posed as Ray-Ban's front, side and three-quarter shots (the side
    /// shot looks down about 11°), kept transparent so their outlines can be laid over the photos.
    func testTheCatalogueMatchFramesRender() throws {
        let shots: [(String, MetaGlassesModel.Live)] = [
            ("meta-match-front", MetaGlassesModel.Live(spin: false, tilt: 0, cameraDistance: 9, spinAngle: 0)),
            ("meta-match-side", MetaGlassesModel.Live(spin: false, tilt: 0.19, cameraDistance: 9, spinAngle: -.pi / 2)),
            ("meta-match-three-quarter", MetaGlassesModel.Live(spin: false, tilt: 0.1, cameraDistance: 9, spinAngle: -0.6)),
        ]
        // As the straight-on shot was taken: from about 40 cm, looking down 7°.
        let photoFront = MetaGlassesModel.Live(spin: false, tilt: 0.122, cameraDistance: 4.0, spinAngle: 0)
        write(try render(photoFront, width: 2000, height: 1000, fieldOfView: 21), "meta-match-front-camera", keepAlpha: true)
        for (name, live) in shots {
            write(try render(live, width: 2000, height: 1000, fieldOfView: 9.5), name, keepAlpha: true)
        }
    }

    /// Folded, the temples lie behind the front: seen from the side the pair is only a few
    /// centimetres deep instead of a whole temple long.
    func testFoldingTucksTheTemplesBehindTheFront() throws {
        let open = MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: .pi / 2)
        let openDepth = drawnBox(try render(open)).width
        let folded = MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: .pi / 2, folded: true)
        XCTAssertTrue(folded.folded)
        let side = try render(folded)
        write(side, "meta-folded-side")
        XCTAssertLessThan(drawnBox(side).width, openDepth * 0.4, "folded temples should sit behind the front")

        write(try render(MetaGlassesModel.Live(spin: false, folded: true)), "meta-folded")
        write(try render(MetaGlassesModel.Live(spin: false, tilt: 0.15, spinAngle: 0, folded: true)), "meta-folded-front")

        folded.setFolded(false, animated: false)
        XCTAssertEqual(drawnBox(try render(folded)).width, openDepth, accuracy: 2, "and open again")
    }

    /// The card spins: at its framing the pair must stay inside the square all the way round.
    func testTheTurntableStaysInsideTheCard() throws {
        var frames: [UIImage] = []
        for step in 0..<8 {
            let angle = 0.62 + Float(step) * .pi / 4
            let frame = try render(MetaGlassesModel.Live(spin: false, spinAngle: angle), width: 240)
            XCTAssertFalse(touchesEdge(frame), "clipped at \(angle) rad")
            frames.append(frame)
            let folded = try render(MetaGlassesModel.Live(spin: false, spinAngle: angle, folded: true), width: 240)
            XCTAssertFalse(touchesEdge(folded), "folded, clipped at \(angle) rad")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = UIGraphicsImageRenderer(size: CGSize(width: 240 * 8, height: 240), format: format).image { _ in
            for (index, frame) in frames.enumerated() { frame.draw(at: CGPoint(x: index * 240, y: 0)) }
        }
        write(strip, "meta-turntable")
    }

    /// A page hero 200 pt tall and about 360 wide takes the closer hero camera; the widest turn
    /// must still fit.
    func testTheHeroRenders() throws {
        let live = MetaGlassesModel.Live(spin: false, cameraDistance: MetaGlassesModel.heroDistance)
        live.setLED(true, animated: false)
        write(try render(live, width: 1080, height: 600), "meta-hero-led")
        for step in 0..<8 {
            let angle = Float(step) * .pi / 4 + 0.3
            let turned = try render(MetaGlassesModel.Live(spin: false, cameraDistance: MetaGlassesModel.heroDistance,
                                                          spinAngle: angle), width: 360, height: 200)
            XCTAssertFalse(touchesEdge(turned), "hero clipped at \(angle) rad")
        }
    }

    /// The SwiftUI view in the Wearables card's stills mode is one drawn frame, no SCNView; on its
    /// own page it is a live view. Written to RING_SNAPSHOT_DIR for a look.
    func testTheSceneViewDrawsAStillOnTheCardAndALiveViewOnThePage() throws {
        XCTAssertEqual(try sceneViews(in: MetaGlassesSceneView(spin: true, ledOn: true).environment(\.sceneStills, true)), 0)
        XCTAssertEqual(try sceneViews(in: MetaGlassesSceneView(spin: true)), 1)
        let card = CGSize(width: 124, height: 124)
        try RenderHarness.write(MetaGlassesSceneView(spin: true).environment(\.sceneStills, true), size: card,
                                name: "meta-still-card")
        try RenderHarness.write(MetaGlassesSceneView(spin: true, ledOn: true).environment(\.sceneStills, true),
                                size: card, name: "meta-still-card-led")
        try RenderHarness.write(MetaGlassesSceneView(spin: true, folded: true).environment(\.sceneStills, true),
                                size: card, name: "meta-still-card-folded")
        try RenderHarness.write(MetaGlassesSceneView(spin: false, ledOn: true).environment(\.sceneStills, true),
                                size: CGSize(width: 360, height: 200), name: "meta-still-hero")
    }


    // MARK: Focus

    /// Pixels that turned clearly blue from one frame to the other: the listening and speaking
    /// markers.
    private func blued(_ marked: UIImage, over plain: UIImage) -> Int {
        let (a, b) = (pixels(of: marked).bytes, pixels(of: plain).bytes)
        guard a.count == b.count else { return 0 }
        return stride(from: 0, to: a.count, by: 4).reduce(0) { total, i in
            let (r, g, blue) = (Int(a[i]), Int(a[i + 1]), Int(a[i + 2]))
            return total + (blue - Int(b[i + 2]) > 40 && blue > r + 40 && blue > g + 10 ? 1 : 0)
        }
    }

    private static let focusShots: [(MetaGlassesPart, MetaGlassesPulse)] = [
        (.camera, .capture), (.led, .recording), (.mic, .listening), (.speakers, .speaking),
        (.touchpad, .touch), (.captureButton, .touch),
    ]

    /// Each part, glided to and marked: one frame per part on black, at the page size and at the
    /// 124 pt card's, and the marker must clearly show at both.
    func testEachPartRendersWithItsFocusMarker() throws {
        for (part, pulse) in Self.focusShots {
            for (suffix, size) in [("", CGFloat(720)), ("-card", CGFloat(248))] {
                let live = MetaGlassesModel.Live(spin: false)
                live.setFocus(MetaGlassesFocus(part: part, pulse: pulse), animated: false)
                let marked = try render(live, width: size)
                write(marked, "meta-focus-\(part.rawValue)\(suffix)")
                live.hideMarkers()
                let plain = try render(live, width: size)
                let blue = pulse == .listening || pulse == .speaking
                let gain = blue ? blued(marked, over: plain) : brightened(marked, over: plain)
                let needed = Int(size * size / 2500)
                XCTAssertGreaterThan(gain, needed, "the \(part) marker should read at \(Int(size)) px")
            }
        }
    }

    /// Clearing the focus puts the camera, the lean and the turn back where they rest.
    func testClearingTheFocusReturnsToTheRestingPose() throws {
        let live = MetaGlassesModel.Live(spin: false)
        let camera = live.camera.position, tilt = live.pivot.eulerAngles.x, turn = live.spinner.eulerAngles.y
        live.setFocus(MetaGlassesFocus(part: .speakers, pulse: .speaking), animated: false)
        XCTAssertGreaterThan(abs(live.camera.position.z - camera.z), 0.5, "the camera should come in close")
        live.setFocus(nil, animated: false)
        XCTAssertNil(live.focus)
        XCTAssertEqual(live.camera.position.x, camera.x, accuracy: 1e-4)
        XCTAssertEqual(live.camera.position.y, camera.y, accuracy: 1e-4)
        XCTAssertEqual(live.camera.position.z, camera.z, accuracy: 1e-4)
        XCTAssertEqual(live.pivot.eulerAngles.x, tilt, accuracy: 1e-4)
        XCTAssertEqual(live.spinner.eulerAngles.y, turn, accuracy: 1e-4)
        XCTAssertNil(live.spinner.action(forKey: "spin"), "a still pair stays still")

        let turning = MetaGlassesModel.Live(spin: true)
        turning.setFocus(MetaGlassesFocus(part: .mic, pulse: .listening), animated: false)
        XCTAssertNil(turning.spinner.action(forKey: "spin"), "the turntable pauses on a focus")
        turning.setFocus(nil, animated: false)
        XCTAssertNotNil(turning.spinner.action(forKey: "spin"), "and turns again after")
        write(try render(turning), "meta-focus-cleared")
    }

    /// From one part straight to the next lands exactly where going there directly does.
    func testOneFocusGoesStraightToTheNext() throws {
        let hop = MetaGlassesModel.Live(spin: false)
        hop.setFocus(MetaGlassesFocus(part: .camera, pulse: .capture), animated: false)
        hop.setFocus(MetaGlassesFocus(part: .touchpad, pulse: .touch), animated: false)
        let direct = MetaGlassesModel.Live(spin: false)
        direct.setFocus(MetaGlassesFocus(part: .touchpad, pulse: .touch), animated: false)
        XCTAssertEqual(hop.camera.position.x, direct.camera.position.x, accuracy: 1e-4)
        XCTAssertEqual(hop.camera.position.y, direct.camera.position.y, accuracy: 1e-4)
        XCTAssertEqual(hop.camera.position.z, direct.camera.position.z, accuracy: 1e-4)
        let hopTurn = remainderf(hop.spinner.eulerAngles.y - direct.spinner.eulerAngles.y, 2 * .pi)
        XCTAssertEqual(hopTurn, 0, accuracy: 1e-4)
    }

    /// The card's stills mode shows a focus too: the camera placed and the marker held.
    func testAStillShowsTheFocus() throws {
        try RenderHarness.write(MetaGlassesSceneView(spin: true, focus: MetaGlassesFocus(part: .speakers, pulse: .speaking))
            .environment(\.sceneStills, true), size: CGSize(width: 124, height: 124), name: "meta-still-card-focus-speakers")
        try RenderHarness.write(MetaGlassesSceneView(spin: true, focus: MetaGlassesFocus(part: .mic, pulse: .listening))
            .environment(\.sceneStills, true), size: CGSize(width: 360, height: 200), name: "meta-still-hero-focus-mic")
    }

    /// SceneKit builds no mesh at all for an extruded outline it can't take (too fine a flatness,
    /// a self-crossing edge), and says nothing: every shape must have come out with vertices.
    func testEveryShapeBuildsAMesh() throws {
        let live = MetaGlassesModel.Live(spin: false, tilt: 0, spinAngle: 0)
        _ = try render(live, width: 200)
        var shapes = 0
        live.scene.rootNode.enumerateChildNodes { node, _ in
            guard let shape = node.geometry as? SCNShape else { return }
            shapes += 1
            let vertices = shape.sources(for: .vertex).first?.vectorCount ?? 0
            XCTAssertGreaterThan(vertices, 0, "an outline \(shape.path?.bounds.width ?? 0) wide built no mesh")
        }
        XCTAssertGreaterThanOrEqual(shapes, 5, "the front, two end pieces and two temples")
    }

    /// The live view glides and pulses: a filmstrip (RING_SNAPSHOT_DIR) of the speakers coming into
    /// focus, then straight on to a photo at the camera, then back to the resting pose.
    func testTheFocusGlidesInALiveView() throws {
        let box = MetaFocusBox()
        try RenderHarness.filmstrip(MetaFocusHost(box: box), size: CGSize(width: 248, height: 248), name: "meta-focus-glide",
                                    changes: [{ box.focus = MetaGlassesFocus(part: .speakers, pulse: .speaking) },
                                              { box.focus = MetaGlassesFocus(part: .camera, pulse: .capture) },
                                              { box.focus = nil }],
                                    times: [0, 0.2, 0.4, 0.6, 0.85, 1.3])
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

/// Holds the focus a filmstrip changes.
@Observable
private final class MetaFocusBox {
    var focus: MetaGlassesFocus?
}

private struct MetaFocusHost: View {
    let box: MetaFocusBox
    var body: some View { MetaGlassesSceneView(spin: false, focus: box.focus) }
}
