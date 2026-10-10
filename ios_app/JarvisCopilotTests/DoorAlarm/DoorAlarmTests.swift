import XCTest
@testable import JarvisCopilot

/// The door alarm on the phone: decoding the server's state, Face ID signing in the `jarvis-home`
/// domain (never the car's), and the device's skills.
@MainActor
final class DoorAlarmTests: XCTestCase {
    static let state: [String: Any] = [
        "setup": ["credentials": true, "region": "us", "hub": true, "hub_name": "Wireless Doorbell",
                  "proxy": "board1", "cloud": "connected"],
        "alarm": ["state": "entry", "mode": "away", "seconds_left": 21, "contact_name": "Front Door",
                  "siren_on": false, "since": 1_800_000_000.0,
                  "settings": ["exit_delay": 60, "entry_delay": 30, "siren_duration": 180]],
        "hub": [
            "name": "Wireless Doorbell", "product_name": "Door chime",
            "contacts": [["id": "dp:doorcontact_state", "name": "Front Door", "open": true, "last_open": 1_800_000_000.0,
                          "instant": false, "active_home": true, "notify_disarmed": false, "on_open_prompt": ""]],
            "dps": [
                ["id": 1, "code": "doorcontact_state", "name": "Door", "type": "bool", "writable": false],
                ["id": 2, "code": "alarm_volume", "name": "Volume", "type": "enum", "writable": true,
                 "range": ["low", "high"]],
                ["id": 4, "code": "battery_percentage", "name": "Battery", "type": "value", "writable": false,
                 "min": 0, "max": 100, "step": 1, "unit": "%"],
            ],
            "values": ["alarm_volume": ["value": "high"], "battery_percentage": ["value": 87],
                       "doorcontact_state": ["value": true]],
            "roles": ["door": ["doorcontact_state"], "volume": ["alarm_volume"]],
            "link": ["local_alive": true, "cloud_alive": false,
                     "local": ["state": "connected", "ip": "192.168.1.50", "version": "3.5", "rtt_ms": 40],
                     "cloud": ["state": "down", "error": "gone"]],
        ],
        "approvals": [["id": "ap1", "command": "disarm", "title": "Disarm the door alarm", "source": "Jarvis",
                       "age_s": 3, "expires_in_s": 117]],
    ]

    private let signer = FakeCarSigner()

    private func api(registered: Bool = true) -> (DoorAlarmAPI, ToyotaApprover, MockTransport) {
        let (jarvis, transport) = JarvisAPI.mocked()
        let key = try! signer.publicKey()
        transport.route("/api/car/approver", json: registered ? ["registered": true, "public_key": key]
                                                               : ["registered": false, "public_key": NSNull()])
        transport.route("/api/door/state", json: Self.state)
        transport.route("/api/door/disarm", json: Self.state)
        transport.route("/api/door/approvals/ap1/approve", json: Self.state)
        return (DoorAlarmAPI(api: jarvis), ToyotaApprover(signer: signer, api: ToyotaAPI(api: jarvis)), transport)
    }

    func testStateDecodesEverythingThePageShows() {
        let s = DoorState(json: Self.state)
        XCTAssertEqual(s.alarm.state, "entry")
        XCTAssertEqual(s.alarm.secondsLeft, 21)
        XCTAssertTrue(s.alarm.isAlerting && s.alarm.isArmed)
        XCTAssertEqual(s.contacts.map(\.name), ["Front Door"])
        XCTAssertEqual(s.openContacts.count, 1)
        XCTAssertEqual(s.settings.map(\.code), ["alarm_volume"])           // the door DP isn't a setting
        XCTAssertEqual(s.readings.map(\.code), ["battery_percentage"])
        XCTAssertEqual(s.settings.first?.value, .text("high"))
        XCTAssertEqual(s.readings.first?.value, .number(87))
        XCTAssertTrue(s.links.localAlive)
        XCTAssertEqual(s.links.localIP, "192.168.1.50")
        XCTAssertEqual(s.approvals.first?.command, "disarm")
    }

    func testJSONBooleansAndNumbersStayApart() {
        XCTAssertEqual(DoorValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(DoorValue(NSNumber(value: 1)), .number(1))
        XCTAssertEqual(DoorValue("open"), .text("open"))
        XCTAssertEqual(DoorValue(nil), .none)
    }

    func testDisarmSignsTheHomeDomainNeverTheCar() async {
        let (api, approver, transport) = api()
        let store = DoorAlarmStore(api: api, approver: approver)
        await store.disarm()
        XCTAssertEqual(signer.signed.count, 1)
        XCTAssertTrue(signer.signed[0].hasPrefix("jarvis-home|disarm|"), signer.signed[0])
        XCTAssertFalse(signer.signed[0].hasPrefix("jarvis-car"))
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/api/door/disarm" }.count, 1)
    }

    func testCancelledFaceIDSendsNothing() async {
        let (api, approver, transport) = api()
        signer.cancel = true
        let store = DoorAlarmStore(api: api, approver: approver)
        await store.disarm()
        XCTAssertTrue(transport.requests.filter { $0.url?.path == "/api/door/disarm" }.isEmpty)
    }

    func testJarvisApprovalsSignTheApprovalIdInTheHomeDomain() async {
        let (api, approver, _) = api()
        let center = DoorApprovals(api: api, approver: approver)
        let approval = DoorApproval(json: ["id": "ap1", "command": "disarm", "expires_in_s": 100])!
        await center.approve(approval)
        XCTAssertEqual(signer.signed.first?.hasPrefix("jarvis-home|disarm|ap1|"), true)
    }

    func testApprovalsNeverSignAnUnknownAction() async {
        let (api, approver, _) = api()
        let center = DoorApprovals(api: api, approver: approver)
        await center.approve(DoorApproval(json: ["id": "x", "command": "unlock_front_door", "expires_in_s": 100])!)
        XCTAssertTrue(signer.signed.isEmpty)
    }

    func testTheDeviceAdvertisesTheTwoPhoneSkills() {
        let device = DoorAlarmDevice(defaults: UserDefaults(suiteName: "door-tests-\(UUID().uuidString)")!)
        XCTAssertEqual(Set(device.capabilities.map(\.name)), ["door_alarm_ring", "door_show_approvals"])
        XCTAssertTrue(device.deviceID.hasPrefix("door-"))
    }
}
