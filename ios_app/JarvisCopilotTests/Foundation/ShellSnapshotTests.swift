import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Layout and chrome regression tests for the shell, hosting the *real*
/// `NavShell` in a real `UIWindow` sized like an iPhone 17 Pro Max
/// (440×956, 62 pt top and 34 pt bottom safe area).
///
/// Two bugs reported from the phone are pinned here:
///
/// 1. **Every screen covered at the bottom by the nav bar.** The pill used to be
///    an overlay with a matching `safeAreaInset` on each page. That inset never
///    arrives: a SwiftUI `NavigationStack` is bridged to a
///    `UINavigationController`, and the bridge re-reads the safe area from the
///    UIKit hierarchy, discarding anything SwiftUI applied outside it. A hierarchy
///    dump showed every page's `UILayoutContainerView` at `bottom: 34` — the raw
///    home indicator — with its content running to the screen edge under the
///    pill. The shell now gives the bar real layout space (Flutter's
///    `Scaffold.bottomNavigationBar`), which a `NavigationStack` does honour.
/// 2. **Two stacked back chevrons on More → Settings.** Six tabs in a `TabView`
///    means `UITabBarController`, which moves tabs 5–6 into the system *More*
///    overflow — a `UIMoreNavigationController` wrapping Coding and More in a
///    second navigation controller, complete with its own back button.
///    `.toolbar(.hidden, for: .tabBar)` hides the bar, not the overflow.
///
/// Assertions are structural (UIKit frames, insets, controller classes) so the
/// file runs headless — SwiftUI builds no accessibility tree unless an assistive
/// technology is attached, so there is nothing to query by label. The PNGs are a
/// debugging by-product, written to ``snapshotDirectory`` and never asserted on.
@MainActor
final class ShellSnapshotTests: XCTestCase {

    // MARK: Harness

    /// iPhone 17 Pro Max in points, plus the insets a window on that device has.
    static let deviceSize = CGSize(width: 440, height: 956)
    static let deviceInsets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)

    static let snapshotDirectory =
        "/private/tmp/claude-501/-Users-pranavkrishna-PranavFiles-coding-projects-JarvisCopilot"
        + "/1e859fd6-70aa-48bf-b84f-8f3c43f1cb44/scratchpad/shell-snapshots"

    /// Holds the window for the duration of a test — one that goes out of scope
    /// tears its hierarchy down mid-assertion.
    private final class Harness {
        let window: UIWindow
        let host: UIHostingController<AnyView>

        init(_ view: some View) {
            // Attach to the test host's scene: an unattached window renders blank
            // through `drawHierarchy` and carries no safe area of its own.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: ShellSnapshotTests.deviceSize)
            host = UIHostingController(rootView: AnyView(view))
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.makeKeyAndVisible()
            // Top up to the reference device's insets — the simulator running the
            // suite is not necessarily a Pro Max, and the bottom-bar arithmetic
            // under test is only interesting against a real home indicator.
            let have = window.safeAreaInsets
            let want = ShellSnapshotTests.deviceInsets
            host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, want.top - have.top),
                                                         left: 0,
                                                         bottom: max(0, want.bottom - have.bottom),
                                                         right: 0)
            settle()
        }

        /// Let SwiftUI build, `.task`s start, and layout land.
        func settle(_ seconds: TimeInterval = 0.4) {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            window.setNeedsLayout()
            window.layoutIfNeeded()
        }

        @discardableResult
        func snapshot(_ name: String) -> String {
            let dir = ShellSnapshotTests.snapshotDirectory
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let path = "\(dir)/\(name).png"
            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
            return path
        }

        /// Where the top edge of the nav pill lands: the bar takes a strip out of
        /// the bottom of the screen and everything else has to end above it.
        var pillTop: CGFloat {
            window.bounds.height
                - GlassNavBar.stripHeight(bottomInset: ShellSnapshotTests.deviceInsets.bottom)
        }
    }

    // MARK: Hierarchy walkers

    private func allViews(_ root: UIView) -> [UIView] {
        root.subviews.reduce([root]) { $0 + allViews($1) }
    }

    private func allControllers(_ root: UIViewController) -> [UIViewController] {
        var found = [root]
        for child in root.children { found += allControllers(child) }
        if let presented = root.presentedViewController { found += allControllers(presented) }
        return found
    }

    private func navigationControllers(in harness: Harness) -> [UINavigationController] {
        allControllers(harness.host).compactMap { $0 as? UINavigationController }
    }

    /// Visible navigation bars. Two of them stacked in one column is exactly what
    /// the user photographed on Settings.
    private func navigationBars(in harness: Harness) -> [UINavigationBar] {
        allViews(harness.window)
            .compactMap { $0 as? UINavigationBar }
            .filter { $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
    }

    /// UIKit builds the chevron out of private views; `BackButtonMaskView` is one
    /// per back button. A cross-check on top of the navigation-bar count, which
    /// is the assertion that actually matters.
    private func backButtonMarkers(in harness: Harness) -> [UIView] {
        allViews(harness.window).filter {
            String(describing: type(of: $0)).contains("BackButtonMaskView")
        }
    }

    /// Scroll views that are laid out and big enough to be a page's content.
    private func scrollViews(in harness: Harness) -> [UIScrollView] {
        allViews(harness.window).compactMap { $0 as? UIScrollView }
            .filter { $0.window != nil && $0.bounds.height > 80 }
    }

    private func frameInWindow(_ view: UIView) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    /// A hidden tab is hidden by an ancestor's opacity, not its own — the page's
    /// views keep `alpha == 1`, so visibility has to be read up the chain.
    private func isVisible(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return true
    }

    /// The navigation stack of whichever tab is showing.
    private func visibleNavigationController(in harness: Harness) -> UINavigationController? {
        navigationControllers(in: harness).first { isVisible($0.view) }
    }

    private func shell(_ router: AppRouter) -> Harness {
        Harness(NavShell().environment(router))
    }

    // MARK: 1 — the shell is six live pages and nothing else

    /// The regression that produced the stray chevron. A `UITabBarController`
    /// with six tabs hides the last two behind a system *More* list, and pages
    /// reached through it are wrapped in a second navigation controller.
    func testShellHasNoTabBarOrOverflowController() {
        let harness = shell(AppRouter())
        let controllers = allControllers(harness.host)
        let names = controllers.map { String(describing: type(of: $0)) }

        XCTAssertFalse(controllers.contains { $0 is UITabBarController },
                       "a UITabBarController splits six tabs into a system More overflow: \(names)")
        XCTAssertFalse(names.contains { $0.contains("MoreNavigation") },
                       "the system More overflow adds a second navigation bar: \(names)")
        XCTAssertNil(allViews(harness.window).first { $0 is UITabBar },
                     "the shell draws its own pill — no UITabBar should exist")
    }

    /// Every page owns its own `NavigationStack` and none is nested inside
    /// another: nesting is what puts two back buttons in the same column.
    func testEachPageOwnsAnUnnestedNavigationStack() {
        let harness = shell(AppRouter())
        let stacks = navigationControllers(in: harness)

        XCTAssertEqual(stacks.count, AppTab.allCases.count,
                       "one navigation stack per tab, all built up front")
        for stack in stacks {
            var parent = stack.parent
            while let current = parent {
                XCTAssertFalse(current is UINavigationController,
                               "a page's stack is nested inside another navigation controller")
                parent = current.parent
            }
        }
    }

    /// `IndexedStack` semantics: switching tabs must not rebuild a page, or its
    /// scroll position, stores and pushed screens would reset.
    func testSwitchingTabsKeepsEveryPageAlive() {
        let router = AppRouter()
        let harness = shell(router)
        let before = Set(navigationControllers(in: harness).map(ObjectIdentifier.init))

        for tab in AppTab.allCases {
            router.selectedTab = tab
            harness.settle(0.2)
        }
        router.selectedTab = .chat
        harness.settle(0.2)

        let after = Set(navigationControllers(in: harness).map(ObjectIdentifier.init))
        XCTAssertEqual(before, after, "a tab switch rebuilt a page instead of revealing it")
    }

    // MARK: 2 — nothing ends under the nav pill

    func testEveryTabEndsAboveTheNavPill() {
        let router = AppRouter()
        let harness = shell(router)

        for tab in AppTab.allCases {
            router.selectedTab = tab
            harness.settle(0.6)
            harness.snapshot("tab-\(tab.rawValue)")

            for stack in navigationControllers(in: harness) {
                let frame = frameInWindow(stack.view)
                XCTAssertLessThanOrEqual(
                    frame.maxY, harness.pillTop + 0.5,
                    "\(tab.rawValue): a page runs to \(frame.maxY), under the pill "
                    + "at \(harness.pillTop)")
            }
            for scroller in scrollViews(in: harness) {
                let usableBottom = frameInWindow(scroller).maxY - scroller.adjustedContentInset.bottom
                XCTAssertLessThanOrEqual(
                    usableBottom, harness.pillTop + 0.5,
                    "\(tab.rawValue): \(type(of: scroller)) content reaches \(usableBottom), "
                    + "under the pill at \(harness.pillTop)")
            }
        }
    }

    /// The chat composer is the bottom-most control in the app and the one the
    /// user watched disappear behind the pill. Its text view is a real `UIView`,
    /// so its frame can be compared with the bar's strip directly.
    func testChatComposerDoesNotIntersectTheNavPill() {
        let router = AppRouter()
        let harness = shell(router)
        router.selectedTab = .chat
        harness.settle(0.5)
        harness.snapshot("chat-composer")

        let editors = allViews(harness.window).filter { $0 is UITextView }
        XCTAssertFalse(editors.isEmpty, "the composer's text view should be laid out")

        let strip = CGRect(x: 0, y: harness.pillTop,
                           width: harness.window.bounds.width,
                           height: harness.window.bounds.height - harness.pillTop)
        for editor in editors {
            let frame = frameInWindow(editor)
            XCTAssertFalse(frame.intersects(strip),
                           "composer \(frame) intersects the nav pill's strip \(strip)")
        }
    }

    /// The pill's own metrics, against `nav.dart`: a 68 pt bar with a 26 pt
    /// radius and a 16 pt horizontal margin, sitting `6 + bottomInset * 0.3`
    /// above the bottom edge. The pages ending exactly at the top of that strip
    /// is the proof the reservation is real rather than merely declared.
    func testNavPillMatchesTheFlutterMetrics() {
        XCTAssertEqual(GlassNavBar.barHeight, 68)
        XCTAssertEqual(GlassNavBar.bottomClearance, 6)
        XCTAssertEqual(JcTheme.pillRadius, 26)
        XCTAssertEqual(GlassNavBar.stripHeight(bottomInset: 34), 6 + 34 * 0.3 + 68, accuracy: 0.001)
        XCTAssertEqual(GlassNavBar.stripHeight(bottomInset: 0), GlassNavBar.reservedHeight)

        let harness = shell(AppRouter())
        harness.snapshot("nav-pill")
        let pageBottoms = navigationControllers(in: harness).map { frameInWindow($0.view).maxY }
        XCTAssertFalse(pageBottoms.isEmpty)
        for bottom in pageBottoms {
            XCTAssertEqual(bottom, harness.pillTop, accuracy: 0.5,
                           "a page should end exactly where the pill's strip begins")
        }
        // The pill hugs the bottom edge rather than floating a whole home
        // indicator above it, as the Flutter bar does.
        let gapUnderPill = GlassNavBar.bottomClearance
            + ShellSnapshotTests.deviceInsets.bottom * GlassNavBar.insetFraction
        XCTAssertLessThan(gapUnderPill, ShellSnapshotTests.deviceInsets.bottom)
    }

    // MARK: 3 — pushed screens have exactly one back button

    func testMoreSettingsPushHasASingleBackButton() {
        let grid = Harness(MorePage().environment(AppRouter()))
        grid.snapshot("more-grid")
        XCTAssertEqual(navigationBars(in: grid).count, 1, "the More grid should show one bar")
        XCTAssertTrue(backButtonMarkers(in: grid).isEmpty, "a tab root has nothing to go back to")

        let harness = Harness(MorePage(path: .constant([.settings])).environment(AppRouter()))
        harness.settle(0.6)
        harness.snapshot("more-settings")

        let stacks = navigationControllers(in: harness)
        XCTAssertEqual(stacks.count, 1, "More → Settings must stay in one navigation stack")
        XCTAssertEqual(stacks.first?.viewControllers.count, 2, "Settings should be pushed")

        let bars = navigationBars(in: harness)
        XCTAssertEqual(bars.count, 1,
                       "two navigation bars is the stacked-chevron bug (found \(bars.count))")
        XCTAssertEqual(backButtonMarkers(in: harness).count, 1,
                       "Settings should show exactly one back chevron")
        XCTAssertEqual(bars.first?.items?.count, 2,
                       "the bar should carry the root and the pushed item")
    }

    /// The report was about Settings *inside the shell*, so push it into the real
    /// navigation controller the More tab owns: same stack the app runs, with the
    /// pill on screen underneath it.
    func testSettingsPushedInsideTheShellKeepsOneChevronAboveThePill() {
        let router = AppRouter()
        let harness = shell(router)
        router.selectedTab = .more
        harness.settle(0.4)

        guard let stack = visibleNavigationController(in: harness) else {
            return XCTFail("no visible navigation stack on the More tab")
        }
        stack.pushViewController(
            UIHostingController(rootView: SettingsPage(store: MainActor.assumeIsolated {
                SettingsStore(preferences: MemoryKeyValueStore())
            }).jcScreen("Settings")),
            animated: false)
        harness.settle(0.5)
        harness.snapshot("shell-more-settings")

        XCTAssertEqual(stack.viewControllers.count, 2, "Settings should be on the stack")
        let bars = navigationBars(in: harness).filter { isVisible($0) }
        XCTAssertEqual(bars.count, 1,
                       "the pushed screen shows \(bars.count) navigation bars — "
                       + "two stacked in one column is the reported bug")
        XCTAssertEqual(backButtonMarkers(in: harness).filter { isVisible($0.superview ?? $0) }.count, 1,
                       "exactly one back chevron")
        XCTAssertLessThanOrEqual(frameInWindow(stack.view).maxY, harness.pillTop + 0.5,
                                 "the pushed screen runs under the nav pill")
    }

    /// The screens Settings itself pushes must not gain a second bar either.
    func testSettingsSubPagesPushWithOneBackButton() {
        for (label, page) in settingsSubPages() {
            let harness = Harness(SettingsPushProbe(pushed: page).environment(AppRouter()))
            harness.settle(0.5)
            harness.snapshot("settings-sub-\(label)")

            let bars = navigationBars(in: harness)
            XCTAssertEqual(bars.count, 1, "\(label): \(bars.count) navigation bars")
            XCTAssertLessThanOrEqual(backButtonMarkers(in: harness).count, 1,
                                     "\(label): more than one back chevron")
        }
    }

    private func settingsSubPages() -> [(String, AnyView)] {
        [
            ("ondevice-ai", AnyView(OnDeviceAISettingsPage())),
            ("code-master", AnyView(CodeMasterSettingsPage())),
            ("server-settings", AnyView(WebViewPage(title: "Server settings", path: "/?panel=settings"))),
            ("bridge", AnyView(BridgeSettingsView())),
        ]
    }

    /// Settings inside its own stack with one of its rows already pushed, so the
    /// navigation-bar arithmetic under test is the pushed screen's own.
    private struct SettingsPushProbe: View {
        let pushed: AnyView

        var body: some View {
            NavigationStack {
                SettingsPage(store: MainActor.assumeIsolated {
                    SettingsStore(preferences: MemoryKeyValueStore())
                })
                .navigationDestination(isPresented: .constant(true)) { pushed }
            }
        }
    }
}
