import XCTest
@testable import JarvisCopilot

/// Live 2026-11-24: after the boards restarted, the Alarm Proxy's page reached the PC power board (stale address),
/// and both pages showed "PC power button". Each board's LAN name follows from its id, and one address belongs to
/// one board only.
final class Esp32AddressTests: XCTestCase {
    func testTheLanNameFollowsFromTheDeviceID() {
        XCTAssertEqual(Esp32KnownBoard.lanName(forDeviceID: "esp32-a4cf12b3cc26"), "jarvis-esp32-cc26")
        XCTAssertNil(Esp32KnownBoard.lanName(forDeviceID: "wifi-jarvis-esp32-cc26"))
    }

    func testItsOwnNameComesFirstAndAStaleNameIsIgnored() {
        let r = Esp32KnownBoard(deviceID: "esp32-a4cf12b3cc26", name: "Alarm", peripheralID: nil,
                                hostname: "jarvis-esp32-622e", ip: "192.168.1.74")
        XCTAssertEqual(r.lanHosts, ["jarvis-esp32-cc26.local", "192.168.1.74"])
    }

    func testBonjourMapsANameToTheBoardItBelongsTo() {
        let alarm = Esp32KnownBoard(deviceID: "esp32-a4cf12b3cc26", name: "Alarm", peripheralID: nil,
                                    hostname: "jarvis-esp32-622e", ip: nil)
        let pc = Esp32KnownBoard(deviceID: "esp32-7c9ebd06622e", name: "PC", peripheralID: nil, hostname: nil, ip: nil)
        XCTAssertEqual(Esp32KnownBoard.record(forHost: "jarvis-esp32-622e", in: [alarm, pc])?.deviceID, pc.deviceID)
        XCTAssertEqual(Esp32KnownBoard.record(forHost: "jarvis-esp32-cc26", in: [alarm, pc])?.deviceID, alarm.deviceID)
    }

    func testOneAddressBelongsToOneBoard() {
        let alarm = Esp32KnownBoard(deviceID: "esp32-a4cf12b3cc26", name: "Alarm", peripheralID: "P1",
                                    hostname: "jarvis-esp32-622e", ip: "192.168.1.74")
        let pc = Esp32KnownBoard(deviceID: "esp32-7c9ebd06622e", name: "PC", peripheralID: "P1",
                                 hostname: "jarvis-esp32-622e", ip: "192.168.1.74")
        let out = Esp32KnownBoard.claimingAddresses(of: pc, from: [alarm])
        XCTAssertNil(out[0].peripheralID)
        XCTAssertNil(out[0].hostname)
        XCTAssertNil(out[0].ip)
    }

    func testWifiIsTriedWithJustItsOwnNameAndAnyKey() {
        let bare = Esp32KnownBoard(deviceID: "esp32-7c9ebd06622e", name: "PC", peripheralID: nil, hostname: nil, ip: nil)
        XCTAssertTrue(Esp32KnownBoard.wifiReachable(bare, phoneHasAKey: true))
        XCTAssertFalse(Esp32KnownBoard.wifiReachable(bare, phoneHasAKey: false))
        let odd = Esp32KnownBoard(deviceID: "wifi-x", name: "X", peripheralID: nil, hostname: nil, ip: nil)
        XCTAssertFalse(Esp32KnownBoard.wifiReachable(odd, phoneHasAKey: true))
    }
}
