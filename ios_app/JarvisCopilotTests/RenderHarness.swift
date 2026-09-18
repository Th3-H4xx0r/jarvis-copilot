import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Draws a view in a real window and writes it to /tmp/ringshots, so a screen
/// can be looked at before it is ever installed on a phone.
@MainActor
enum RenderHarness {
    static func write(_ view: some View, size: CGSize, name: String, settle: TimeInterval = 2.5) throws {
        let host = UIHostingController(rootView:
            view
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .background(JcTheme.bg))
        // A screen has no Dynamic Island inset here; the test window would inherit one.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let image = UIGraphicsImageRenderer(size: size).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] ?? "/tmp/ringshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("\(name).png"))
    }
}
