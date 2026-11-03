import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The grey filter bar spans the full width whenever its labels fit — the
/// five-item D W M 6M Y bar once hugged its labels at the left.
@MainActor
final class JcSegmentedWidthTests: XCTestCase {
    private struct Choice: Hashable, Identifiable {
        let id: String
    }

    private func trackBrightnessNearRightEdge(_ labels: [String], width: CGFloat = 360) -> CGFloat {
        let items = labels.map(Choice.init)
        let view = JcSegmented(items: items, selection: .constant(items[0]), label: \.id)
            .frame(width: width, height: 44)
            .background(Color.black)
        let size = CGSize(width: width, height: 44)
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true

        // One pixel, 16 pt in from the right edge, halfway down.
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -(width - 16), y: -22))
        }
        let data = pixel.cgImage!.dataProvider!.data! as Data
        return CGFloat(Int(data[0]) + Int(data[1]) + Int(data[2])) / (3 * 255)
    }

    func testFiveShortLabelsFillTheWidth() {
        XCTAssertGreaterThan(trackBrightnessNearRightEdge(["D", "W", "M", "6M", "Y"]), 0.05,
                             "the grey track should reach the right edge")
    }

    func testThreeLabelsFillTheWidth() {
        XCTAssertGreaterThan(trackBrightnessNearRightEdge(["Day", "Week", "Month"]), 0.05)
    }
}
