import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders "put the band on" — the hand, the forearm grown out of its wrist, and the band on its
/// way over the hand — so its look can be judged before it reaches a phone. Frames go to
/// `/tmp/ringshots` (the simulator shares the Mac's /tmp). A `band-stage.json` there
/// (`{"euler": [x, y, z], "lookAt": [x, y, z], "distance": d}`) overrides the framing, to try a
/// framing without a rebuild.
@MainActor
final class BandWearPromptRenderTests: XCTestCase {
    private let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] ?? "/tmp/ringshots")

    private func stage() throws -> BandHandModel.Stage {
        let hand = try XCTUnwrap(BandHandModel.bundled, "BandHand.bin (the fist) ships in the app bundle")
        var pose = BandHandModel.Stage.handEuler, lookAt = BandHandModel.Stage.lookAt
        var distance = BandHandModel.Stage.distance
        if let data = try? Data(contentsOf: out.appendingPathComponent("band-stage.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = json["euler"] as? [Double], e.count == 3 { pose = SCNVector3(Float(e[0]), Float(e[1]), Float(e[2])) }
            if let l = json["lookAt"] as? [Double], l.count == 3 { lookAt = SIMD3(Float(l[0]), Float(l[1]), Float(l[2])) }
            if let d = json["distance"] as? Double { distance = Float(d) }
        }
        return try XCTUnwrap(BandHandModel.Stage(band: BandModel.makeNode(), hand: hand,
                                                 accent: UIColor(JcTheme.accent).cgColor,
                                                 pose: pose, lookAt: lookAt, distance: distance))
    }

    private func write(_ image: UIImage, name: String) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("RENDERED \(file.path)")
    }

    private func snapshot(_ stage: BandHandModel.Stage) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        let frame = renderer.snapshot(atTime: 0, with: CGSize(width: 1206, height: 660), antialiasingMode: .multisampling4X)
        return UIGraphicsImageRenderer(size: frame.size).image { context in
            UIColor(white: 0.07, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: frame.size))
            frame.draw(at: .zero)
        }
    }

    /// The band past the fingertip, part way over the hand, closing on the wrist, and seated.
    func testTheBandOnItsWayRenders() throws {
        let stage = try stage()
        for s: Float in [0, 0.3, 0.55, 0.75, 0.9, 1] {
            stage.pose(along: s)
            try write(try snapshot(stage), name: "band-wear-\(Int(s * 100))")
        }
        // The bare arm, ghost and band away: the forearm's join must not show.
        stage.pose(along: 0, ghost: false)
        try write(try snapshot(stage), name: "band-wear-bare")
    }

    /// The whole slide as numbered frames, for a preview clip — only when `band-sequence` exists
    /// in the output folder (it costs a few seconds).
    func testTheGestureAsFrames() throws {
        guard FileManager.default.fileExists(atPath: out.appendingPathComponent("band-sequence").path) else {
            throw XCTSkip("touch /tmp/ringshots/band-sequence to render the frames")
        }
        let stage = try stage()
        let count = 58
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            stage.pose(along: BandHandModel.slideEase(t), ghost: i < count * 3 / 4)
            try write(try snapshot(stage), name: String(format: "band-seq-%02d", i))
        }
    }

    /// Building the stage (measuring the fist, the strap's morph target) happens as the sheet
    /// opens, on the main thread: it must stay quick.
    func testTheStageBuildsQuickly() throws {
        let fist = try XCTUnwrap(BandHandModel.bundled)
        let started = Date()
        _ = try XCTUnwrap(BandHandModel.Stage(band: BandModel.makeNode(), hand: fist,
                                             accent: UIColor(JcTheme.accent).cgColor))
        let took = Date().timeIntervalSince(started)
        print("BAND STAGE BUILD \(took)s")
        XCTAssertLessThan(took, 1.0)
    }

    /// The loop never closes tighter than its seat on the way, and opens to clear the palm.
    func testThePathOpensOverTheHandAndClosesOnTheWrist() throws {
        let path = try stage().path
        let stretches = path.stops.map(\.stretch)
        XCTAssertEqual(stretches.last, 1)
        XCTAssertGreaterThan(stretches.max() ?? 0, 1.3, "the palm is wider than the wrist")
        XCTAssertTrue(zip(stretches, stretches.dropFirst()).allSatisfy { $0 >= $1 }, "it only closes on the way in")
        XCTAssertEqual(path.stops.last?.x ?? 0, BandHandModel.wristX, accuracy: 1e-4)
        XCTAssertGreaterThan(path.widest, 1.3, "the strap's morph target is opened")
    }

    func testTheSheetRendersWithTheBandSeated() throws {
        let size = CGSize(width: 402, height: 430)
        let host = UIHostingController(rootView:
            RingWearPrompt(metric: "Heart rate", kind: .band, pinnedSeated: true) {}
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .background(RingWearPrompt.sheetBackground))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        XCTAssertEqual(image.size, size)
        try write(image, name: "band-wear-sheet")
    }
}
