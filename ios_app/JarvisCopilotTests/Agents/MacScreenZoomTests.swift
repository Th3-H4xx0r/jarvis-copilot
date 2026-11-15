import XCTest
@testable import JarvisCopilot

final class MacScreenZoomTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    func testUnzoomedMapsStraightThrough() {
        let z = MacScreenZoom()
        XCTAssertEqual(z.base(CGPoint(x: 120, y: 80)), CGPoint(x: 120, y: 80))
    }

    func testPinchKeepsTheSpotUnderTheFingers() {
        var z = MacScreenZoom()
        let center = CGPoint(x: 200, y: 150)
        z.pinch(by: 2, at: center, in: size)
        XCTAssertEqual(z.scale, 2)
        XCTAssertEqual(z.base(center).x, 200, accuracy: 0.001)
        XCTAssertEqual(z.base(center).y, 150, accuracy: 0.001)
        // A tap at the top-left of the zoomed view is a quarter of the way in, not the corner.
        XCTAssertEqual(z.base(.zero).x, 100, accuracy: 0.001)
        XCTAssertEqual(z.base(.zero).y, 75, accuracy: 0.001)
    }

    func testScaleIsClampedBetweenOneAndMax() {
        var z = MacScreenZoom()
        z.pinch(by: 0.5, at: CGPoint(x: 10, y: 10), in: size)
        XCTAssertEqual(z, MacScreenZoom())
        z.pinch(by: 50, at: CGPoint(x: 10, y: 10), in: size)
        XCTAssertEqual(z.scale, MacScreenZoom.maxScale)
    }

    func testPanNeverShowsPastTheEdges() {
        var z = MacScreenZoom()
        z.pinch(by: 2, at: CGPoint(x: 200, y: 150), in: size)
        z.pan(by: CGSize(width: 10_000, height: 10_000), in: size)
        XCTAssertEqual(z.offset, .zero)
        z.pan(by: CGSize(width: -10_000, height: -10_000), in: size)
        XCTAssertEqual(z.offset, CGPoint(x: -400, y: -300))
    }

    func testZoomingBackOutResets() {
        var z = MacScreenZoom()
        z.pinch(by: 3, at: CGPoint(x: 50, y: 50), in: size)
        z.pinch(by: 1.0 / 3.0, at: CGPoint(x: 300, y: 200), in: size)
        XCTAssertFalse(z.isZoomed)
        XCTAssertEqual(z.offset, .zero)
    }
}
