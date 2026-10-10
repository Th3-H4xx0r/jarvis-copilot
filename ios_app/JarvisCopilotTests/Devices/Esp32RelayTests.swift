import XCTest
@testable import JarvisCopilot

/// The ESP32's iPhone-notification relay: frames as the firmware builds them
/// (`send_ios_notification` / `handle_notify_relay` in JarvisEsp32.ino).
final class Esp32RelayTests: XCTestCase {
    private func frame(_ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let body = [op] + payload
        var f: [UInt8] = [Esp32Protocol.sync, UInt8(body.count)] + body
        f.append(Esp32Protocol.crc8(f[1...]))
        return f
    }

    private func lp(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [UInt8(b.count)] + b }

    func testIosNotificationEventDecodes() throws {
        let payload: [UInt8] = [4] + lp("com.apple.MobileSMS") + lp("Mom") + lp("Dinner at 7? 🍝")
        guard case .event(let event, let p)? = Esp32Protocol.decode(frame(0xE9, payload)) else {
            return XCTFail("not decoded as an event")
        }
        XCTAssertEqual(event, .iosNotification)
        let n = try XCTUnwrap(Esp32Protocol.parseIosNotification(p))
        XCTAssertEqual(n.category, 4)
        XCTAssertEqual(n.appID, "com.apple.MobileSMS")
        XCTAssertEqual(n.title, "Mom")
        XCTAssertEqual(n.message, "Dinner at 7? 🍝")
    }

    func testIosNotificationAllowsEmptyTitle() throws {
        let n = try XCTUnwrap(Esp32Protocol.parseIosNotification([6] + lp("com.google.Gmail") + lp("") + lp("New mail")))
        XCTAssertEqual(n.title, "")
        XCTAssertEqual(n.message, "New mail")
    }

    func testTruncatedNotificationIsRejected() {
        var p: [UInt8] = [4] + lp("app") + lp("title") + lp("message")
        p.removeLast()
        XCTAssertNil(Esp32Protocol.parseIosNotification(p))
        XCTAssertNil(Esp32Protocol.parseIosNotification([]))
    }

    func testRelayStatusResponseDecodes() throws {
        // status ok, on, receiving, forwarded = 300
        guard case .response(let op, let status, let p)? = Esp32Protocol.decode(frame(0x4C | 0x80, [0, 1, 2, 0x01, 0x2C])) else {
            return XCTFail("not decoded as a response")
        }
        XCTAssertEqual(op, Esp32Protocol.Op.notifyRelay.rawValue)
        XCTAssertEqual(status, .ok)
        let r = try XCTUnwrap(Esp32Protocol.parseRelayStatus(p))
        XCTAssertTrue(r.on)
        XCTAssertEqual(r.state, .receiving)
        XCTAssertEqual(r.forwarded, 300)
    }

    func testRelayStatusRejectsUnknownState() {
        XCTAssertNil(Esp32Protocol.parseRelayStatus([1, 9, 0, 0]))
        XCTAssertNil(Esp32Protocol.parseRelayStatus([1, 2]))
    }
}

/// Two paired boards (the glasses relay and the door alarm's proxy) each keep their own name.
@MainActor
final class Esp32NamesTests: XCTestCase {
    func testRenamingOneBoardLeavesTheOtherAlone() {
        let a = "test-board-a-\(UUID().uuidString)", b = "test-board-b-\(UUID().uuidString)"
        defer {
            WearableNames.shared.renameEsp32(id: a, to: "")
            WearableNames.shared.renameEsp32(id: b, to: "")
        }
        WearableNames.shared.renameEsp32(id: b, to: "ESP32 Alarm Proxy")
        XCTAssertEqual(WearableNames.shared.esp32Name(id: b, fallback: "Jarvis-ESP32-BBBB"), "ESP32 Alarm Proxy")
        XCTAssertEqual(WearableNames.shared.esp32Name(id: a, fallback: "Jarvis-ESP32-AAAA"), "Jarvis-ESP32-AAAA")
        WearableNames.shared.renameEsp32(id: a, to: "Glasses Relay")
        XCTAssertEqual(WearableNames.shared.esp32Name(id: a, fallback: "x"), "Glasses Relay")
        XCTAssertEqual(WearableNames.shared.esp32Name(id: b, fallback: "x"), "ESP32 Alarm Proxy")
    }
}
