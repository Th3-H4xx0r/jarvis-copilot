import AppKit
import XCTest
@testable import Jarvis

/// The iPhone's Dock menu for a Mac app: "I would like to press and hold the icons of open apps
/// to see menu for them … if I have multiple vsc windows, I can't switch it from the iOS app".
/// The Mac lists an app's windows over the share's data channel and raises the one he picks.
final class MacWindowsTests: XCTestCase {

    func testTheReplyCarriesEachWindowSmall() {
        let long = String(repeating: "x", count: 400)
        let windows = [
            MacWindowInfo(id: 4211, title: "jarvis-copilot — MacControls.swift", minimized: false, front: true),
            MacWindowInfo(id: 4302, title: long, minimized: true, front: false),
        ]
        let reply = MacWindows.payload(pid: 812, windows: windows, canNewWindow: true, ax: true)
        XCTAssertEqual(J.s(reply["t"]), "cc_windows")
        XCTAssertEqual(J.i(reply["pid"]), 812)
        XCTAssertTrue(J.b(reply["new_window"]))
        XCTAssertTrue(J.b(reply["ax"]))
        let rows = J.arr(reply["windows"])
        XCTAssertEqual(rows.map { J.i($0["id"]) }, [4211, 4302])
        XCTAssertEqual(J.s(rows[0]["title"]), "jarvis-copilot — MacControls.swift")
        XCTAssertTrue(J.b(rows[0]["front"]))
        XCTAssertTrue(J.b(rows[1]["min"]))
        XCTAssertLessThanOrEqual(J.s(rows[1]["title"]).count, MacWindows.maxTitle)
        XCTAssertTrue(J.s(rows[1]["title"]).hasSuffix("…"))
        // Small enough for one data-channel message.
        let bytes = try! JSONSerialization.data(withJSONObject: reply).count
        XCTAssertLessThan(bytes, 1000)
    }

    func testAnAppWithDozensOfWindowsSendsOnlyTheFirstFew() {
        let many = (0..<80).map { MacWindowInfo(id: $0 + 1, title: "Window \($0)", minimized: false, front: $0 == 0) }
        let rows = J.arr(MacWindows.payload(pid: 1, windows: many, canNewWindow: false, ax: true)["windows"])
        XCTAssertEqual(rows.count, MacWindows.maxWindows)
        XCTAssertEqual(J.i(rows.first?["id"]), 1)
    }

    func testOnlyRealWindowsAreListed() {
        XCTAssertTrue(MacWindows.keep(subrole: "AXStandardWindow", title: "Untitled"))
        XCTAssertTrue(MacWindows.keep(subrole: "AXStandardWindow", title: ""))
        XCTAssertTrue(MacWindows.keep(subrole: "AXDialog", title: "Save"))
        XCTAssertTrue(MacWindows.keep(subrole: nil, title: "Some window"))
        XCTAssertFalse(MacWindows.keep(subrole: nil, title: ""))
        XCTAssertFalse(MacWindows.keep(subrole: "AXUnknown", title: ""))
        XCTAssertFalse(MacWindows.keep(subrole: "AXSystemDialog", title: "x"))
    }

    func testAPickedWindowIsFoundByItsIdEvenAfterTheOrderChanged() {
        let now = [MacWindowInfo(id: 9, title: "b", minimized: false, front: true),
                   MacWindowInfo(id: 7, title: "a", minimized: true, front: false)]
        XCTAssertEqual(MacWindows.index(of: 7, in: now), 1)
        XCTAssertNil(MacWindows.index(of: 8, in: now), "a closed window is never swapped for another")
        // Without window numbers the id is the position (-1 = first).
        XCTAssertEqual(MacWindows.fallbackID(index: 0), -1)
        XCTAssertEqual(MacWindows.fallbackID(index: 3), -4)
    }

    func testNewWindowMenuItemsAreRecognised() {
        XCTAssertTrue(MacWindows.isNewWindowTitle("New Window"))
        XCTAssertTrue(MacWindows.isNewWindowTitle("New Finder Window"))
        XCTAssertTrue(MacWindows.isNewWindowTitle("New Private Window"))
        XCTAssertFalse(MacWindows.isNewWindowTitle("New File"))
        XCTAssertFalse(MacWindows.isNewWindowTitle("New Tab"))
        XCTAssertFalse(MacWindows.isNewWindowTitle("Close Window"))
        XCTAssertFalse(MacWindows.isNewWindowTitle("New Window with Profile"))
    }

    func testThePlainNewWindowItemWinsOverAPrivateOne() {
        let titles = ["New Tab", "New Private Window", "New Window", "Open…"]
        XCTAssertEqual(MacWindows.bestNewWindow(titles), 2)
        XCTAssertEqual(MacWindows.bestNewWindow(["New Finder Window", "New Folder"]), 0)
        XCTAssertNil(MacWindows.bestNewWindow(["New File", "Open…"]))
    }

    // MARK: the channel

    private func ask(_ m: [String: Any], until done: @escaping ([String: Any]) -> Bool) -> [[String: Any]] {
        final class Box: @unchecked Sendable { var got: [[String: Any]] = [] }
        let box = Box()
        let finished = expectation(description: "reply")
        finished.assertForOverFulfill = false
        let controls = MacControls(pipeline: nil) { obj in
            DispatchQueue.main.async {
                box.got.append(obj)
                if done(obj) { finished.fulfill() }
            }
        }
        controls.handle(m)
        wait(for: [finished], timeout: 10)
        return box.got
    }

    func testWindowsOfAnAppThatIsGoneAreAnEmptyList() {
        let got = ask(["t": "cc", "do": "windows", "pid": 999_999]) { J.s($0["t"]) == "cc_windows" }
        let reply = got.first { J.s($0["t"]) == "cc_windows" }
        XCTAssertEqual(J.i(reply?["pid"]), 999_999)
        XCTAssertTrue(J.arr(reply?["windows"]).isEmpty)
        XCTAssertFalse(got.contains { J.s($0["t"]) == "cc_state" }, "a windows list never costs a full state read")
    }

    func testRaisingAWindowOfAGoneAppSaysSo() {
        let got = ask(["t": "cc", "do": "window", "pid": 999_999, "id": 12]) { J.s($0["t"]) == "cc_error" }
        let error = got.first { J.s($0["t"]) == "cc_error" }
        XCTAssertEqual(J.s(error?["do"]), "window")
        XCTAssertFalse(J.s(error?["error"]).isEmpty)
    }

    /// Read-only, on his real Mac: `TEST_RUNNER_JARVIS_LIVE_WINDOWS=1 xcodebuild test …`
    /// lists Visual Studio Code's windows the way the phone will see them. Nothing is raised.
    func testLiveListOfVSCodeWindows() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_WINDOWS"] == "1" else {
            throw XCTSkip("live check: set TEST_RUNNER_JARVIS_LIVE_WINDOWS=1")
        }
        let code = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.microsoft.VSCode" }
        let pid = Int(try XCTUnwrap(code, "VS Code isn't running").processIdentifier)
        let got = ask(["t": "cc", "do": "windows", "pid": pid]) { J.s($0["t"]) == "cc_windows" }
        let reply = try XCTUnwrap(got.first { J.s($0["t"]) == "cc_windows" })
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        print("LIVE cc_windows (\(data.count) bytes): \(String(decoding: data, as: UTF8.self))")
        XCTAssertTrue(J.b(reply["ax"]), "Jarvis has no Accessibility permission here")
    }
}
