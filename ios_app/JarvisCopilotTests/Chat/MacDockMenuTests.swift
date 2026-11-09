import XCTest
@testable import JarvisCopilot

/// "I would like to press and hold the icons of open apps to see menu for them … if I have
/// multiple vsc windows, I can't switch it from the iOS app, it would be nice to have a tap and
/// hold with a popover that comes up with all these options just like a Mac taskbar."
@MainActor
final class MacDockMenuTests: XCTestCase {
    /// What MacWindows.payload sends (shape captured from the Mac's live VS Code reply).
    private let reply: [String: Any] = [
        "t": "cc_windows", "pid": 1228, "ax": true, "new_window": true,
        "windows": [
            ["id": 6106, "title": "jarvis-copilot — MacScreenViewer.swift", "min": false, "front": true],
            ["id": 8291, "title": "hermes — run_agent.py", "min": false, "front": false],
            ["id": -3, "title": "", "min": true, "front": false],
            ["title": "no id"],
        ],
    ]

    func testTheMacsWindowListDecodes() throws {
        let list = try XCTUnwrap(MacAppWindows(json: reply))
        XCTAssertEqual(list.pid, 1228)
        XCTAssertTrue(list.canNewWindow)
        XCTAssertTrue(list.accessibility)
        XCTAssertEqual(list.windows.map(\.id), [6106, 8291, -3])
        XCTAssertEqual(list.windows.first?.front, true)
        XCTAssertEqual(list.windows[2].minimized, true)
        XCTAssertEqual(list.windows[2].label, "Untitled window")
        XCTAssertNil(MacAppWindows(json: ["t": "cc_windows"]), "no pid, no list")
    }

    func testTheSessionKeepsEachAppsWindowsAndKnowsTheMacCanDoIt() {
        let session = MacScreenSession(shareID: "t")
        XCTAssertEqual(session.windowSupport, .unknown)
        session.receivedForTesting(reply)
        XCTAssertEqual(session.windowSupport, .yes)
        XCTAssertEqual(session.windows[1228]?.windows.count, 3)
    }

    func testAnOlderMacSaysItDoesntKnowWindowsAndNothingTurnsRed() {
        let session = MacScreenSession(shareID: "t")
        // MacControls.run's default branch on a build from before the Dock menu.
        session.receivedForTesting(["t": "cc_error", "do": "windows",
                                    "error": "The Mac app doesn't know “windows” yet: update Jarvis on the Mac."])
        XCTAssertEqual(session.windowSupport, .no)
        XCTAssertNil(session.controlError, "the Command Center's red line is for things he did")
    }

    func testMenuContentForEachCase() throws {
        let list = try XCTUnwrap(MacAppWindows(json: reply))
        let loaded = MacDockMenuContent.resolve(support: .yes, windows: list, waitedOut: false)
        XCTAssertEqual(loaded.windows.map(\.id), [6106, 8291, -3])
        XCTAssertEqual(loaded.actions, [.newWindow, .showAll, .hide, .quit])
        XCTAssertNil(loaded.note)

        let noNewWindow = try XCTUnwrap(MacAppWindows(json: ["t": "cc_windows", "pid": 3, "new_window": false,
                                                             "ax": true, "windows": [Any]()]))
        XCTAssertEqual(MacDockMenuContent.resolve(support: .yes, windows: noNewWindow, waitedOut: false).actions,
                       [.showAll, .hide, .quit])

        let old = MacDockMenuContent.resolve(support: .no, windows: nil, waitedOut: false)
        XCTAssertEqual(old.note, "Update Jarvis on your Mac to see its windows")
        XCTAssertTrue(old.windows.isEmpty)
        XCTAssertEqual(old.actions, [.showAll, .hide], "only what an older Mac app can still do safely")

        // A Mac app that never answers at all (no Command Center) is an older one too.
        XCTAssertEqual(MacDockMenuContent.resolve(support: .unknown, windows: nil, waitedOut: true), old)
        let waiting = MacDockMenuContent.resolve(support: .unknown, windows: nil, waitedOut: false)
        XCTAssertTrue(waiting.loading)
        XCTAssertNil(waiting.note)

        let noAX = try XCTUnwrap(MacAppWindows(json: ["t": "cc_windows", "pid": 3, "ax": false, "windows": [Any]()]))
        let blocked = MacDockMenuContent.resolve(support: .yes, windows: noAX, waitedOut: false)
        XCTAssertEqual(blocked.note, "Allow Jarvis in Accessibility on your Mac to see its windows")
        XCTAssertEqual(blocked.actions, [.showAll, .hide, .quit])
    }

    func testActionsGoAsTheirOwnMessagesOnAnUpdatedMac() {
        XCTAssertEqual(MacDockAction.newWindow.steps(pid: 9, updatedMac: true), [.cc("app_new_window", pid: 9)])
        XCTAssertEqual(MacDockAction.showAll.steps(pid: 9, updatedMac: true), [.cc("app_show_all", pid: 9)])
        XCTAssertEqual(MacDockAction.hide.steps(pid: 9, updatedMac: true), [.cc("app_hide", pid: 9)])
        XCTAssertEqual(MacDockAction.quit.steps(pid: 9, updatedMac: true), [.cc("app_quit", pid: 9)])
    }

    func testAnOlderMacStillShowsAndHidesTheAppButNeverGuessesAQuit() {
        XCTAssertEqual(MacDockAction.showAll.steps(pid: 9, updatedMac: false), [.cc("app", pid: 9)])
        XCTAssertEqual(MacDockAction.hide.steps(pid: 9, updatedMac: false),
                       [.cc("app", pid: 9), .key("h", mods: ["cmd"])])
        // ⌘Q after an activation that didn't happen would quit whatever app is in front.
        XCTAssertTrue(MacDockAction.quit.steps(pid: 9, updatedMac: false).isEmpty)
        XCTAssertTrue(MacDockAction.newWindow.steps(pid: 9, updatedMac: false).isEmpty)
    }

    func testPickingAWindowRaisesThatExactWindow() {
        XCTAssertEqual(MacDockStep.raise(pid: 1228, window: 8291).message, ["t": "cc", "do": "window", "pid": 1228, "id": 8291])
        XCTAssertEqual(MacDockStep.cc("app_quit", pid: 1228).message, ["t": "cc", "do": "app_quit", "pid": 1228])
        XCTAssertEqual(MacDockStep.key("h", mods: ["cmd"]).message, ["t": "key", "key": "h", "mods": ["cmd"]])
    }
}
