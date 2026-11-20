import XCTest
@testable import JarvisCopilot

/// His unlock permission (2026-11-20): one Face ID lets Jarvis unlock the PC or Mac without asking each time, until
/// it ends (30 days at most, his pick). The computer checks this exact signed message against the key it pins.
final class MacUnlockGrantTests: XCTestCase {
    func testTheSignedMessageCoversTheDeviceAndTheEnd() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let g = MacUnlockGrant.make(device: "pc-1", seconds: 3600, now: now, id: String(repeating: "ab", count: 16))
        XCTAssertEqual(g.ts, 1_800_000_000)
        XCTAssertEqual(g.until, 1_800_003_600)
        XCTAssertEqual(g.message, MacPasswordWire.message(kind: "unlock-grant", nonce: String(repeating: "ab", count: 16),
                                                           ts: 1_800_000_000,
                                                           context: "unlock-grant device=pc-1 until=1800003600"))
    }

    func testChoicesNeverGoPastThirtyDays() {
        XCTAssertEqual(MacUnlockGrant.durations.map(\.label), ["1 hour", "8 hours", "1 day", "7 days", "30 days"])
        XCTAssertTrue(MacUnlockGrant.durations.allSatisfy { $0.seconds <= MacPasswordWire.grantMaxSeconds })
        let g = MacUnlockGrant.make(device: "pc-1", seconds: 90 * 86400, now: Date(), id: MacUnlockGrant.newID())
        XCTAssertLessThanOrEqual(g.until - g.ts, MacPasswordWire.grantMaxSeconds)   // clamped
        XCTAssertNotNil(MacUnlockGrant.newID().range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testTheCardSaysWhetherItsOn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AgentsMacPowerCopy.grantSubtitle(nil, now: now), "Off · Face ID each time")
        XCTAssertTrue(AgentsMacPowerCopy.grantSubtitle(now.addingTimeInterval(3600), now: now).hasPrefix("On until "))
    }

    func testTheListCarriesTheEnd() {
        let mac = AgentMacPower(json: ["device_id": "pc-1", "state": "awake", "os": "windows",
                                       "unlock_grant_until": 1_800_003_600])
        XCTAssertEqual(mac.unlockGrantUntil, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertNil(AgentMacPower(json: ["device_id": "pc-1", "state": "awake"]).unlockGrantUntil)
    }
}
