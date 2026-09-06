import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// The polish pass on the finished shell: the two things that were still wrong
/// once `NavShell` started giving the nav pill REAL layout space.
///
/// 1. **Voice reserved the pill twice.** While the pill was an overlay, every
///    page had to compensate for it itself, and `VoicePage` did — 74 pt of
///    bottom padding that "stood down if the ambient inset arrived". The shell
///    now ends each page above the pill, so the ambient inset it watched for is
///    0 and never arrives: the compensation stayed on top of the reservation and
///    the mic button floated a whole bar-height too high. What is pinned here is
///    the CLEARANCE — the gap between the bottom-most control and the top of the
///    pill's strip — measured for Voice and Coding off the blue of their bottom
///    button and for Chat off the composer's real `UITextView`.
///
/// 2. **The Wearables half carried a second chrome row.** `ScanView` predates the
///    port and brings its own `NavigationStack`, title and toolbar, so embedded
///    under the Devices segmented picker it drew a second navigation bar BELOW
///    the picker (and a flat black background of its own over the aurora). It now
///    takes `embedded: true` and lends its toolbar to the parent's bar.
///
/// The PNGs in ``polishSnapshotDirectory`` are the point of the class during
/// design work; the assertions are what keeps it honest headless.
@MainActor
final class ShellPolishSnapshotTests: XCTestCase {

    // MARK: Harness

    /// iPhone 17 Pro Max in points, and the insets a window on that device has.
    static let deviceSize = CGSize(width: 440, height: 956)
    static let deviceInsets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)

    static let polishSnapshotDirectory =
        "/private/tmp/claude-501/-Users-pranavkrishna-PranavFiles-coding-projects-JarvisCopilot"
        + "/1e859fd6-70aa-48bf-b84f-8f3c43f1cb44/scratchpad/polish-snapshots"

    /// A bottom control that ends more than this far above the pill has reserved
    /// space for it twice. The honest clearances are Voice ~27 pt (12 pt of
    /// padding plus the mic ring's overhang), Chat ~20 pt and Coding ~18 pt; the
    /// double reserve put Voice at ~101.
    private static let maxClearance: CGFloat = 46

    /// Holds the window for the duration of a test — one that goes out of scope
    /// tears its hierarchy down mid-assertion.
    private final class PolishHarness {
        let window: UIWindow
        let host: UIHostingController<AnyView>

        init(_ view: some View) {
            // Attach to the test host's scene: an unattached window renders blank
            // through `drawHierarchy` and carries no safe area of its own.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: ShellPolishSnapshotTests.deviceSize)
            window.overrideUserInterfaceStyle = .dark
            host = UIHostingController(rootView: AnyView(view))
            host.overrideUserInterfaceStyle = .dark
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            // Top up to the reference device's insets — the simulator running the
            // suite is not necessarily a Pro Max, and the bottom-bar arithmetic
            // under test is only interesting against a real home indicator.
            let have = window.safeAreaInsets
            let want = ShellPolishSnapshotTests.deviceInsets
            host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, want.top - have.top),
                                                         left: 0,
                                                         bottom: max(0, want.bottom - have.bottom),
                                                         right: 0)
            settle()
        }

        deinit {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// Let SwiftUI build, `.task`s start, and layout land.
        func settle(_ seconds: TimeInterval = 0.5) {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            window.setNeedsLayout()
            window.layoutIfNeeded()
        }

        func image() -> UIImage {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            return renderer.image { context in
                if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                    window.layer.render(in: context.cgContext)
                }
            }
        }

        @discardableResult
        func snapshot(_ name: String) -> UIImage {
            let dir = ShellPolishSnapshotTests.polishSnapshotDirectory
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let image = self.image()
            try? image.pngData()?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            return image
        }

        /// Where the top edge of the nav pill's strip lands: the bar takes that
        /// strip out of the bottom of the screen and everything else has to end
        /// above it.
        var pillTop: CGFloat {
            window.bounds.height
                - GlassNavBar.stripHeight(bottomInset: ShellPolishSnapshotTests.deviceInsets.bottom)
        }
    }

    private func polishShell(_ router: AppRouter) -> PolishHarness {
        PolishHarness(NavShell().environment(router))
    }

    // MARK: Hierarchy walkers

    private func polishAllViews(_ root: UIView) -> [UIView] {
        root.subviews.reduce([root]) { $0 + polishAllViews($1) }
    }

    /// A hidden tab is hidden by an ancestor's opacity, not its own.
    private func polishIsVisible(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return true
    }

    private func polishFrame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: nil) }

    // MARK: Pixel probe

    /// The bottom-most row of "button blue" in `image`, in points, ignoring
    /// anything at or below `above`.
    ///
    /// SwiftUI draws a `Button` into its parent's layer, so the mic and the
    /// Launch capsule have no `UIView` of their own to measure — but both are the
    /// only saturated blue on their screen, and the nav pill's own blue badge is
    /// excluded by the cut-off. Cheap, and it fails loudly (nil) if the screen
    /// didn't paint at all.
    private func polishBottomOfBlue(in image: UIImage, above cutoff: CGFloat) -> CGFloat? {
        guard let cg = image.cgImage else { return nil }
        let width = Int(Self.deviceSize.width)
        let height = Int(Self.deviceSize.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let limit = min(height, max(0, Int(cutoff)))
        for y in stride(from: limit - 1, through: 0, by: -1) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if b > 140 && b > r + 50 && b > g + 40 { return CGFloat(y + 1) }
            }
        }
        return nil
    }

    // MARK: 1 — the bottom control clears the pill by one gap, not two

    /// The bug: `VoicePage.navBarReserve` added `GlassNavBar.reservedHeight` on
    /// top of the space the shell already takes, so the mic sat a whole bar-height
    /// above where it belongs.
    func testVoiceMicSitsJustAboveTheNavPill() {
        let router = AppRouter()
        router.selectedTab = .voice
        let harness = polishShell(router)
        harness.settle(0.8)
        let image = harness.snapshot("voice-in-shell")

        guard let micBottom = polishBottomOfBlue(in: image, above: harness.pillTop) else {
            return XCTFail("no mic button found above the pill — did the Voice tab paint?")
        }
        let clearance = harness.pillTop - micBottom
        XCTAssertGreaterThan(clearance, 0, "the mic overlaps the nav pill")
        XCTAssertLessThan(clearance, Self.maxClearance,
                          "the mic clears the pill by \(clearance) pt — the page is reserving "
                          + "\(GlassNavBar.reservedHeight) pt the shell already reserved")
    }

    /// Chat is the reference clearance: its composer is the bottom-most control
    /// in the app and the one that was checked by hand on the phone.
    func testChatComposerSitsJustAboveTheNavPill() {
        let router = AppRouter()
        router.selectedTab = .chat
        let harness = polishShell(router)
        harness.settle(0.8)
        harness.snapshot("chat-in-shell")

        let editors = polishAllViews(harness.window)
            .filter { $0 is UITextView && polishIsVisible($0) }
        XCTAssertFalse(editors.isEmpty, "the composer's text view should be laid out")
        for editor in editors {
            let clearance = harness.pillTop - polishFrame(editor).maxY
            XCTAssertGreaterThan(clearance, 0, "the composer overlaps the nav pill")
            XCTAssertLessThan(clearance, Self.maxClearance,
                              "the composer clears the pill by \(clearance) pt")
        }
    }

    /// Coding's Launch capsule is its bottom-most control, and the same blue.
    func testCodingLaunchButtonSitsJustAboveTheNavPill() {
        let router = AppRouter()
        router.selectedTab = .coding
        let harness = polishShell(router)
        harness.settle(0.8)
        let image = harness.snapshot("coding-in-shell")

        guard let buttonBottom = polishBottomOfBlue(in: image, above: harness.pillTop) else {
            return XCTFail("no Launch button found above the pill — did the Coding tab paint?")
        }
        let clearance = harness.pillTop - buttonBottom
        XCTAssertGreaterThan(clearance, 0, "the Launch button overlaps the nav pill")
        XCTAssertLessThan(clearance, Self.maxClearance,
                          "the Launch button clears the pill by \(clearance) pt")
    }

    // MARK: 2 — the Wearables half has no chrome of its own

    /// `ScanView` embedded must not bring a second navigation bar, and the one bar
    /// the Devices tab does show has to be ABOVE the segmented picker — a bar
    /// underneath it is the stacked chrome row the user photographed.
    func testWearablesHalfHasNoSecondChromeRow() {
        let router = AppRouter()
        router.selectedTab = .devices
        let harness = polishShell(router)
        harness.settle(0.8)
        harness.snapshot("devices-wearables")

        let bars = polishAllViews(harness.window)
            .compactMap { $0 as? UINavigationBar }
            .filter { polishIsVisible($0) }
        XCTAssertEqual(bars.count, 1,
                       "the Devices tab shows \(bars.count) navigation bars — a second one under "
                       + "the picker is `ScanView`'s own chrome")

        let pickers = polishAllViews(harness.window)
            .compactMap { $0 as? UISegmentedControl }
            .filter { polishIsVisible($0) }
        XCTAssertEqual(pickers.count, 1, "the Server/Wearables picker should be on screen")

        guard let bar = bars.first, let picker = pickers.first else { return }
        XCTAssertLessThanOrEqual(polishFrame(bar).maxY, polishFrame(picker).minY + 0.5,
                                 "the navigation bar is drawn UNDER the segmented picker")
    }

    // MARK: 3 — the legacy bridge screen wears the port's chrome

    /// `BridgeSettingsView` predates the port and was still a bare scroller on
    /// flat system black under a stock title. It now carries `.jcScreen("Bridge")`
    /// so the aurora runs behind it and its bar matches every other pushed
    /// screen — without touching a line of its pairing behaviour.
    func testBridgeSettingsWearsTheScreenChrome() {
        let harness = PolishHarness(
            NavigationStack { BridgeSettingsView() }.environment(AppRouter()))
        harness.settle(0.6)
        harness.snapshot("bridge-settings")

        let bars = polishAllViews(harness.window)
            .compactMap { $0 as? UINavigationBar }
            .filter { polishIsVisible($0) }
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.topItem?.title, "Bridge")

        // The aurora can only show if the scroller stopped painting over it.
        let scrollers = polishAllViews(harness.window)
            .compactMap { $0 as? UIScrollView }
            .filter { polishIsVisible($0) && $0.bounds.height > 200 }
        XCTAssertFalse(scrollers.isEmpty, "the bridge form should be laid out")
        for scroller in scrollers {
            let alpha = scroller.backgroundColor?.cgColor.alpha ?? 0
            XCTAssertEqual(alpha, 0, accuracy: 0.01,
                           "an opaque scroll background hides the aurora")
        }
    }

    /// The scanner keeps its own chrome when it is the whole screen — `embedded`
    /// is additive and must not change the standalone look.
    func testStandaloneScanViewKeepsItsOwnNavigationStack() {
        let embedded = PolishHarness(
            NavigationStack { ScanView(embedded: true) }.environment(AppRouter()))
        embedded.settle(0.4)
        let inner = polishAllViews(embedded.window).compactMap { $0 as? UINavigationBar }
        XCTAssertEqual(inner.count, 1, "an embedded scanner must not add a stack of its own")

        let standalone = PolishHarness(ScanView().environment(AppRouter()))
        standalone.settle(0.4)
        standalone.snapshot("devices-wearables-standalone")
        XCTAssertEqual(polishAllViews(standalone.window)
            .compactMap { $0 as? UINavigationBar }.filter { polishIsVisible($0) }.count, 1,
            "the standalone scanner still owns its bar")
    }
}
