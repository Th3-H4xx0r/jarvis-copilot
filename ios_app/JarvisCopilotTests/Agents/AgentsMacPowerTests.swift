import XCTest
@testable import JarvisCopilot

/// The MacBook card and Mac password prompts: `mac` and `password_requests`
/// decoded from the list, the waking line's timing, the exact bytes the Mac
/// verifies, and that Allow sends the signed yes while a cancelled Face ID
/// sends nothing.
@MainActor
final class AgentsMacPowerTests: XCTestCase {

    /// The two new keys of `GET /api/coding/agents/list` (`mac_power.py`).
    static let fixture = #"""
    {
      "needs_you": [], "projects": [], "ts": 1700000000,
      "mac": [
        {"device_id": "mac-1", "name": "MacBook", "state": "awake", "held": true, "reason": "session",
         "keep_awake": false, "timer_on": true, "battery": 82, "on_ac": false, "lid": "closed",
         "seen_at": 1700000000.5, "wake_requested_at": null},
        {"device_id": "mac-2", "name": "Studio", "state": "sleeping", "held": false, "reason": "",
         "keep_awake": true, "timer_on": false, "battery": null, "on_ac": null, "lid": null,
         "seen_at": 1699999700, "wake_requested_at": 1699999990}
      ],
      "password_requests": [
        {"id": "pw-1", "device_id": "mac-1", "kind": "sudo", "context": "sudo in jarvis: brew install jq",
         "nonce": "abc123", "expires": 1700000120}
      ]
    }
    """#

    private func list() throws -> AgentsList {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as? [String: Any])
        return AgentsList(json: json)
    }

    func testDecodesMacsAndPasswordRequests() throws {
        let list = try list()
        XCTAssertEqual(list.mac.count, 2)
        let book = list.mac[0]
        XCTAssertEqual(book.deviceId, "mac-1")
        XCTAssertEqual(book.name, "MacBook")
        XCTAssertEqual(book.state, .awake)
        XCTAssertTrue(book.held)
        XCTAssertEqual(book.reason, "session")
        XCTAssertFalse(book.keepAwake)
        XCTAssertTrue(book.timerOn)
        XCTAssertEqual(book.battery, 82)
        XCTAssertEqual(book.onAC, false)
        XCTAssertEqual(book.lid, "closed")
        XCTAssertNil(book.wakeRequestedAt)
        let studio = list.mac[1]
        XCTAssertEqual(studio.state, .sleeping)
        XCTAssertTrue(studio.keepAwake)
        XCTAssertFalse(studio.timerOn)
        XCTAssertNil(studio.battery, "null is unknown, not 0")
        XCTAssertNil(studio.onAC)
        XCTAssertNil(studio.lid)
        XCTAssertEqual(studio.wakeRequestedAt, Date(timeIntervalSince1970: 1699999990))

        let request = try XCTUnwrap(list.passwordRequests.first)
        XCTAssertEqual(request.id, "pw-1")
        XCTAssertEqual(request.deviceId, "mac-1")
        XCTAssertEqual(request.kind, "sudo")
        XCTAssertEqual(request.context, "sudo in jarvis: brew install jq")
        XCTAssertEqual(request.nonce, "abc123")
        XCTAssertEqual(request.expires, Date(timeIntervalSince1970: 1700000120))
        XCTAssertFalse(list.isEmpty, "a Mac card alone is something to show")
    }

    func testAListWithoutTheNewKeysStillDecodes() {
        let list = AgentsList(json: ["needs_you": [], "projects": []])
        XCTAssertTrue(list.mac.isEmpty)
        XCTAssertTrue(list.passwordRequests.isEmpty)
    }

    func testPasswordRequestsCountAsWaiting() throws {
        let store = AgentsStore(api: AgentsAPI(api: JarvisAPI.mocked().0), topics: BridgeTopics())
        store.show(try list())
        XCTAssertEqual(store.passwordRequests.map(\.id), ["pw-1"])
        XCTAssertEqual(store.waitingCount, 1)
    }

    // MARK: the card's words

    private func mac(_ state: String, reason: String = "", seen: Double? = 1_700_000_000,
                     wake: Double? = nil) -> AgentMacPower {
        var json: [String: Any] = ["device_id": "mac-1", "name": "MacBook", "state": state, "reason": reason]
        if let seen { json["seen_at"] = seen }
        if let wake { json["wake_requested_at"] = wake }
        return AgentMacPower(json: json)
    }

    func testWakingLineTiming() {
        let asked = 1_700_000_000.0
        let waking = mac("sleeping", seen: asked - 3600, wake: asked)
        let at = { (s: Double) in Date(timeIntervalSince1970: asked + s) }
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(5)), "Waking…")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(60)), "Waking…")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(61)),
                       "Waking… up to 15 min if it's in deep sleep")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(900)),
                       "Waking… up to 15 min if it's in deep sleep")
        // The server drops an intent this old: back to the plain asleep line.
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(1300)), "Asleep · last seen 1 h ago")
    }

    func testAwakeAndAsleepLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake", reason: "session"), now: now), "Awake · Claude working")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake"), now: now), "Awake")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake", reason: "manual", wake: 1_700_000_000), now: now),
                       "Awake · Keep awake on", "an awake Mac is never 'Waking…'")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("sleeping"), now: now), "Asleep · last seen 5 min ago")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("offline", seen: nil), now: now), "Offline")
    }

    // MARK: the signed yes

    func testSignedMessageBytes() {
        // the same bytes the Mac's ApprovalVerifier.message builds (MacPasswordTests.testMessageFormat)
        let data = MacPasswordApproval.message(kind: "sudo", nonce: "abc123", ts: 1_700_000_000, context: "hi")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "jarvis-mac-password|sudo|abc123|1700000000|8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
    }

    func testTitlesAndCountdown() {
        XCTAssertEqual(MacPasswordApproval.title(kind: "sudo"), "sudo in Claude session")
        XCTAssertEqual(MacPasswordApproval.title(kind: "unlock"), "Unlock Mac")
        let expires = Date(timeIntervalSince1970: 1_700_000_120)
        XCTAssertEqual(MacPasswordApproval.countdown(expires, now: Date(timeIntervalSince1970: 1_700_000_015)),
                       "1:45 left")
        XCTAssertEqual(MacPasswordApproval.countdown(expires, now: expires), "Expired")
    }

    private final class FakeSigner: CarSigner, @unchecked Sendable {
        var cancel = false
        var signed: Data?
        func publicKey() throws -> String { "pub" }
        func authenticate(reason: String) async throws -> CarSignerAuth {
            if cancel { throw CarSignError.cancelled }
            return CarSignerAuth(context: nil)
        }
        func sign(_ message: Data, auth: CarSignerAuth) async throws -> Data {
            signed = message
            return Data([0x30, 0x01, 0x02])
        }
    }

    func testAllowPostsTheSignatureAndTime() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let signer = FakeSigner()
        let request = try XCTUnwrap(try list().passwordRequests.first)
        let before = Int(Date().timeIntervalSince1970)
        try await MacPasswordApproval.allow(request, api: AgentsAPI(api: client), signer: signer)

        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/coding/agents/mac/password/answer")
        let body = transport.lastBody()
        XCTAssertEqual(body["id"] as? String, "pw-1")
        XCTAssertEqual(body["decision"] as? String, "allow")
        XCTAssertEqual(body["signature"] as? String, Data([0x30, 0x01, 0x02]).base64EncodedString())
        let ts = try XCTUnwrap(body["ts"] as? Int)
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertEqual(signer.signed, MacPasswordApproval.message(kind: "sudo", nonce: "abc123", ts: ts,
                                                                  context: request.context))
    }

    func testCancelledFaceIDSendsNothing() async throws {
        let (client, transport) = JarvisAPI.mocked()
        let signer = FakeSigner()
        signer.cancel = true
        let request = try XCTUnwrap(try list().passwordRequests.first)
        do {
            try await MacPasswordApproval.allow(request, api: AgentsAPI(api: client), signer: signer)
            XCTFail("cancelled Face ID must throw")
        } catch {
            XCTAssertEqual(error as? CarSignError, .cancelled)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDenyPostsWithoutASignature() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let request = try XCTUnwrap(try list().passwordRequests.first)
        try await MacPasswordApproval.deny(request, api: AgentsAPI(api: client))
        let body = transport.lastBody()
        XCTAssertEqual(body["decision"] as? String, "deny")
        XCTAssertNil(body["signature"])
        XCTAssertNil(body["ts"])
    }
}
