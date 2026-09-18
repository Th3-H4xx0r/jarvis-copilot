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
        try save(image, name: name)
    }

    /// An animation, as a filmstrip: after each change, the frames at `times`
    /// seconds, one row per change — so a transition is looked at, not guessed.
    static func filmstrip(_ view: some View, size: CGSize, name: String, changes: [() -> Void],
                          times: [TimeInterval] = [0, 0.06, 0.12, 0.18, 0.26, 0.4]) throws {
        let host = UIHostingController(rootView:
            view
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .background(JcTheme.bg))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        var rows: [[UIImage]] = []
        for change in changes {
            change()
            let changed = Date()
            rows.append(times.map { time in
                RunLoop.current.run(until: changed.addingTimeInterval(time))
                return UIGraphicsImageRenderer(size: size).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
            })
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        window.isHidden = true

        let gap: CGFloat = 6
        let sheet = CGSize(width: CGFloat(times.count) * (size.width + gap), height: CGFloat(rows.count) * (size.height + gap))
        let image = UIGraphicsImageRenderer(size: sheet).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: sheet))
            for (r, row) in rows.enumerated() {
                for (c, frame) in row.enumerated() {
                    frame.draw(at: CGPoint(x: CGFloat(c) * (size.width + gap), y: CGFloat(r) * (size.height + gap)))
                }
            }
        }
        try save(image, name: name)
    }

    private static func save(_ image: UIImage, name: String) throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] ?? "/tmp/ringshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("\(name).png"))
    }
}
