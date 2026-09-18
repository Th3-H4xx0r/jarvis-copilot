import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders the "put the ring on" sheet so its look can be checked before it is
/// ever installed on a phone.
///
/// Set `RING_SNAPSHOT_DIR` and the frames are written there as PNGs: the ring
/// off-stage and the ring seated on the finger. Without it the test still runs
/// and only asserts the view lays out.
@MainActor
final class RingWearPromptRenderTests: XCTestCase {

    private func render(_ view: some View, size: CGSize, name: String) throws {
        let host = UIHostingController(rootView:
            view
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .background(RingWearPrompt.sheetBackground))
        // A sheet has no Dynamic Island inset; the test window would inherit one.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // The ring is a SceneKit view; give it a moment to draw a frame.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        let image = UIGraphicsImageRenderer(size: size).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        XCTAssertEqual(image.size, size)
        try write(image, name: name)
    }

    private func write(_ image: UIImage, name: String) throws {
        // Always written: the point of this test is to look at the result, and
        // an environment variable does not survive the trip into the simulator.
        let out = ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] ?? "/tmp/ringshots"
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("RENDERED \(file.path)")
    }

    /// The hand and the real ring, straight out of SceneKit: a window snapshot
    /// cannot always see into a Metal view, and this is the part worth checking.
    func testTheHandAndRingRender() throws {
        for (name, seated) in [("hand-seated", true), ("hand-offstage", false)] {
            let hand = try XCTUnwrap(RingHandModel.bundled, "RingHand.bin ships in the app bundle")
            let stage = RingHandModel.Stage(ring: RingModel.makeNode().pivot, hand: hand,
                                            accent: UIColor(JcTheme.accent).cgColor)
            stage.pose(seated: seated)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = stage.scene
            renderer.pointOfView = stage.camera
            let frame = renderer.snapshot(atTime: 0, with: CGSize(width: 1206, height: 660),
                                          antialiasingMode: .multisampling4X)
            let image = UIGraphicsImageRenderer(size: frame.size).image { context in
                UIColor(white: 0.07, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: frame.size))
                frame.draw(at: .zero)
            }
            XCTAssertGreaterThan(image.size.width, 0)
            try write(image, name: name)
        }
    }

    func testTheSheetRendersWithTheRingSeated() throws {
        try render(RingWearPrompt(metric: "Heart rate", pinnedSeated: true) {},
                   size: CGSize(width: 402, height: 430), name: "wear-prompt-seated")
    }

    func testTheSheetRendersWithTheRingOffStage() throws {
        try render(RingWearPrompt(metric: "Heart rate", pinnedSeated: false) {},
                   size: CGSize(width: 402, height: 430), name: "wear-prompt-offstage")
    }
}
