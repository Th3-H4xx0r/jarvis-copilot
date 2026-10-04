import Metal
import XCTest
@testable import JarvisCopilot

/// The wearables' 3D models, rendered to pictures the widget can show.
@MainActor
final class WidgetModelSnapshotTests: XCTestCase {

    private func visiblePixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
    }

    func testEachModelRendersOnATransparentBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        for device in WidgetModelSnapshots.devices {
            let image = try XCTUnwrap(WidgetModelSnapshots.render(device, size: 160), device)
            let visible = visiblePixels(image)
            XCTAssertGreaterThan(visible, 160 * 160 / 50, "\(device) drew something")
            XCTAssertLessThan(visible, 160 * 160, "\(device) has a transparent background")
        }
    }

    func testAnUnknownDeviceHasNoModel() {
        XCTAssertNil(WidgetModelSnapshots.render("toaster", size: 64))
    }

    func testRenderingWritesThePicturesTheWidgetReads() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        WidgetModelSnapshots.renderAll(into: dir, size: 96)
        for device in WidgetModelSnapshots.devices {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(device).png").path), device)
        }
    }

    /// The JARVIS Voice widget shows the phone's real voice orb, not the app icon:
    /// a widget can't run the orb's Metal shader, so the app renders it like the models.
    func testTheVoiceOrbIsRenderedForTheWidget() throws {
        XCTAssertTrue(WidgetModelSnapshots.devices.contains("orb"))
        let image = try XCTUnwrap(WidgetModelSnapshots.render("orb", size: 160))
        XCTAssertFalse(WidgetModelSnapshots.isBlank(image))
    }
}
