import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Pull-to-refresh draws the Jarvis loader (JcRefreshLoader): a real UIRefreshControl,
/// laid out at a pulled height, hides the system spinner and feeds our loader.
@MainActor
final class JcRefreshLoaderTests: XCTestCase {

    func testRefreshControlHostsTheJarvisLoaderAndHidesTheSystemSpinner() throws {
        JcRefreshLoader.install()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let control = UIRefreshControl()
        scroll.refreshControl = control
        let window = UIWindow(frame: scroll.frame)
        window.addSubview(scroll)
        window.makeKeyAndVisible()

        control.frame = CGRect(x: 0, y: -60, width: 390, height: 60)
        control.setNeedsLayout()
        control.layoutIfNeeded()

        let shown = control.subviews.filter { $0.alpha > 0 }
        XCTAssertEqual(shown.count, 1, "only the Jarvis loader shows; the system spinner is hidden")
        let host = try XCTUnwrap(shown.first)
        XCTAssertEqual(host.center.x, control.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(host.center.y, control.bounds.midY, accuracy: 0.5)
    }

    func testPullDrawsTheRingsInStep() {
        // Faint rings at rest, part of ring A mid-pull, the full logo at the end.
        func ink(_ progress: Double) -> Int {
            let renderer = ImageRenderer(content:
                Canvas { ctx, _ in JcPullLoader.render(in: &ctx, size: 48, progress: progress) }
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.white))
            renderer.scale = 1
            guard let cg = renderer.cgImage, let data = cg.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data) else { return 0 }
            var count = 0
            for i in stride(from: 3, to: CFDataGetLength(data), by: 4) where bytes[i] > 200 { count += 1 }
            return count
        }
        let rest = ink(0), half = ink(0.5), full = ink(1)
        XCTAssertLessThan(rest, half)
        XCTAssertLessThan(half, full)
    }
}
