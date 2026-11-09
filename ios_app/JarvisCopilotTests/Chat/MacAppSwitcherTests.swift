import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Mac live view's open-apps switcher. It used to be an empty popover whenever the Mac
/// never answered (a Jarvis Mac app from before the Command Center ignores `t:"cc"`): the
/// list stayed empty and nothing said why.
@MainActor
final class MacAppSwitcherTests: XCTestCase {
    /// What MacControls.sendApps really sends (captured from the Mac code).
    private let macReply: [String: Any] = ["t": "cc_apps", "apps": [
        ["active": false, "pid": 1222, "hidden": false, "name": "Messages", "bundle": "com.apple.MobileSMS"],
        ["bundle": "com.brave.Browser", "pid": 1224, "active": true, "name": "Brave Browser", "hidden": false],
        ["name": "Code", "pid": 1228, "active": false, "bundle": "com.microsoft.VSCode", "hidden": true],
        ["name": "No pid"],
    ]]

    func testTheMacsReplyDecodesEveryAppInOrder() {
        let apps = MacApp.list(from: macReply)
        XCTAssertEqual(apps.map(\.name), ["Messages", "Brave Browser", "Code"])
        XCTAssertEqual(apps.map(\.pid), [1222, 1224, 1228])
        XCTAssertEqual(apps.first(where: \.active)?.bundle, "com.brave.Browser")
    }

    func testAppsArrivingOverTheChannelMarkTheListLoaded() {
        let session = MacScreenSession(shareID: "t")
        XCTAssertFalse(session.appsLoaded)
        session.receivedForTesting(macReply)
        XCTAssertTrue(session.appsLoaded)
        XCTAssertEqual(session.apps.count, 3)
        session.receivedForTesting(["t": "cc_apps", "apps": [Any]()])
        XCTAssertTrue(session.appsLoaded)
        XCTAssertTrue(session.apps.isEmpty)
    }

    private func content(live: Bool = true, apps: [MacApp] = [], appsLoaded: Bool = false,
                         controlsLoaded: Bool = false, error: String? = nil,
                         waitedOut: Bool = false) -> MacAppSwitcherContent {
        .resolve(live: live, apps: apps, appsLoaded: appsLoaded, controlsLoaded: controlsLoaded,
                 error: error, waitedOut: waitedOut)
    }

    func testTheSwitcherIsNeverBlank() {
        let apps = MacApp.list(from: macReply)
        XCTAssertEqual(content(apps: apps, appsLoaded: true), .apps(apps))
        XCTAssertEqual(content(live: false), .connecting)
        XCTAssertEqual(content(), .loading)
        // The Mac answered: no apps really means none.
        XCTAssertEqual(content(appsLoaded: true, controlsLoaded: true), .empty)
        // No answer at all after waiting: the Mac's Jarvis predates the Command Center.
        XCTAssertEqual(content(waitedOut: true), .macTooOld)
        // Switches came back but no apps.
        if case .failed = content(controlsLoaded: true, waitedOut: true) {} else { XCTFail("expected failed") }
        XCTAssertEqual(content(error: "boom", waitedOut: true), .failed("boom"))
        for state in [content(live: false), content(), content(appsLoaded: true), content(waitedOut: true),
                      content(controlsLoaded: true, waitedOut: true)] {
            XCTAssertFalse(state.message?.isEmpty ?? true, "\(state) has no message")
        }
    }

    func testSwitchAppOpensThePhonesSwitcherInsteadOfCommandTab() {
        XCTAssertEqual(MacShortcut.all.filter(\.opensAppSwitcher).map(\.title), ["Switch App"])
    }

    // MARK: renders (to /tmp/ringshots)

    private func popover(_ session: MacScreenSession) -> some View {
        HStack(spacing: 0) {
            Color.black
            Color(white: 0.1).frame(width: 64)
                .popover(isPresented: .constant(true), arrowEdge: .trailing) {
                    MacAppSwitcher(session: session, layout: .column)
                        .presentationCompactAdaptation(.popover)
                }
        }
    }

    func testRenderRailSwitcher() throws {
        let withApps = MacScreenSession(shareID: "preview")
        withApps.receivedForTesting(macReply)
        try RenderHarness.write(popover(withApps), size: CGSize(width: 874, height: 402),
                                name: "mac-switcher-apps", settle: 3)
        try RenderHarness.write(popover(MacScreenSession(shareID: "preview")), size: CGSize(width: 874, height: 402),
                                name: "mac-switcher-waiting", settle: 3)
    }
}
