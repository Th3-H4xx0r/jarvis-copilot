import XCTest
@testable import JarvisCopilot

/// The PC in Agents (Windows client, 2026-11-15): the same card as the Mac, told apart by
/// `os`, with Wake PC / Sleep / Lock and never Unlock; its live view's Command Center shows
/// only what Windows has; a share asks for the PC by its device id.
@MainActor
final class AgentsPcPowerCardTests: XCTestCase {

    private func row(_ json: [String: Any]) -> AgentMacPower {
        AgentMacPower(json: ["device_id": "pc-1", "name": "Pranav-Desktop", "state": "awake"].merging(json) { $1 })
    }

    func testPcRowDecodesOsAndWake() {
        let pc = row(["os": "windows", "wake_capable": false, "wake_reason": "this Wi-Fi adapter can't wake the PC"])
        XCTAssertTrue(pc.isPC)
        XCTAssertEqual(pc.wakeCapable, false)
        XCTAssertEqual(pc.wakeReason, "this Wi-Fi adapter can't wake the PC")
    }

    func testOldRowDefaultsToMac() {
        let mac = AgentMacPower(json: ["device_id": "mac-1", "name": "MacBook", "state": "awake"])
        XCTAssertEqual(mac.os, "macos")
        XCTAssertFalse(mac.isPC)
        XCTAssertNil(mac.wakeCapable)
    }

    func testWakeTitleByOs() {
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "windows"), "Wake PC")
        XCTAssertEqual(AgentsMacPowerCopy.wakeTitle(os: "macos"), "Wake Mac")
    }

    func testPcActionsHideUnlock() {
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "windows"])), [.letSleep, .lock])
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "macos"])), [.letSleep, .unlock])
        XCTAssertEqual(AgentsMacPowerCopy.actions(for: row(["os": "windows", "state": "sleeping"])), [.wake])
    }

    func testPcNameKeptAsWindowsHasIt() {
        XCTAssertEqual(AgentsMacPowerCopy.cardName("Pranav-Desktop", os: "windows"), "Pranav-Desktop")
        XCTAssertEqual(AgentsMacPowerCopy.cardName("", os: "windows"), "Your PC")
        XCTAssertEqual(AgentsMacPowerCopy.cardName("Pranavs-MacBook-Pro.local", os: "macos"), "Pranav's MacBook Pro")
    }

    func testWakeLine() {
        XCTAssertEqual(AgentsMacPowerCopy.wakeLine(row(["os": "windows", "wake_capable": true])),
                       "Wakes over Wi-Fi from your other computer")
        XCTAssertEqual(AgentsMacPowerCopy.wakeLine(row(["os": "windows", "wake_capable": false])),
                       "This PC's Wi-Fi adapter can't be woken remotely")
    }

    func testLockActionPath() {
        XCTAssertEqual(AgentsStore.MacPowerAction.lock.path, "lock")
    }

    func testCommandCenterShowsOnlyWindowsSwitchesForPc() {
        XCTAssertEqual(MacControlItem.switchItems(isPC: true), [.wifi, .bluetooth, .dark])
        XCTAssertFalse(MacControlItem.switchItems(isPC: true).contains(.stage))
        XCTAssertTrue(MacControlItem.switchItems(isPC: false).contains(.stage))
        XCTAssertEqual(MacControlItem.powerButtons(isPC: true), [.lock, .sleep])
        XCTAssertEqual(MacControlItem.powerButtons(isPC: false), [.unlock, .lock, .sleep])
    }

    func testShareAsksForItsComputer() {
        XCTAssertEqual(MacScreenSession.shareRequest(deviceId: "pc-1")["device_id"] as? String, "pc-1")
        XCTAssertEqual(MacScreenSession.shareRequest(deviceId: "pc-1")["reason"] as? String, "anytime")
        XCTAssertNil(MacScreenSession.shareRequest(deviceId: nil)["device_id"])
    }

    func testAdminApprovalTitleInTheAppsWords() {
        XCTAssertEqual(PcAdminCopy.title(source: "Pranav-Desktop"), "Run as admin on Pranav-Desktop")
        XCTAssertEqual(PcAdminCopy.title(source: ""), "Run as admin on your PC")
    }
}
