import SwiftUI
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
                       "Waking… · up to 15 min from deep sleep")
        XCTAssertEqual(AgentsMacPowerCopy.status(waking, now: at(900)).tone, .waking)
        // The server drops an intent this old: back to the plain asleep line.
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(waking, now: at(1300)), "Asleep · last seen 1 h ago")
    }

    func testAwakeAndAsleepLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake", reason: "session"), now: now), "Awake · Claude is working")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake"), now: now), "Awake")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("awake", reason: "manual", wake: 1_700_000_000), now: now),
                       "Awake · Kept awake", "an awake Mac is never 'Waking…'")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("sleeping"), now: now), "Asleep · last seen 5 min ago")
        XCTAssertEqual(AgentsMacPowerCopy.stateLine(mac("offline", seen: nil), now: now), "Offline")
        XCTAssertEqual(AgentsMacPowerCopy.status(mac("sleeping"), now: now),
                       .init(tone: .asleep, label: "Asleep", detail: "last seen 5 min ago"))
        XCTAssertEqual(AgentsMacPowerCopy.reason("grace"), "A session just finished")
        XCTAssertEqual(AgentsMacPowerCopy.reason("remote"), "Woken from iPhone")
        XCTAssertNil(AgentsMacPowerCopy.reason("rtc/Alarm"), "an unknown reason says nothing")
    }

    func testFriendlyName() {
        let name = AgentsMacPowerCopy.friendlyName
        XCTAssertEqual(name("Pranavs-MacBook-Pro.local"), "Pranav's MacBook Pro")
        XCTAssertEqual(name("Pranavs-MacBook-Air"), "Pranav's MacBook Air")
        XCTAssertEqual(name("pranavs-macbook-pro.local"), "Pranav's MacBook Pro")
        XCTAssertEqual(name("Pranavs-MacBook-Pro-2.local"), "Pranav's MacBook Pro", "macOS's clash number goes")
        XCTAssertEqual(name("Jamess-iMac.local"), "James's iMac")
        XCTAssertEqual(name("Studio-Mac-mini.local"), "Studio Mac mini",
                       "an owner without the possessive s stays as it is")
        XCTAssertEqual(name("Annas-Mac-Studio"), "Anna's Mac Studio")
        XCTAssertEqual(name("MacBook-Pro.local"), "MacBook Pro")
        XCTAssertEqual(name("Pranav’s MacBook Pro"), "Pranav’s MacBook Pro", "already words: kept")
        XCTAssertEqual(name("build-box.local"), "build box")
        XCTAssertEqual(name("MacBook"), "MacBook")
        XCTAssertEqual(name(""), "Your Mac")
        XCTAssertEqual(name(".local"), "Your Mac")
    }

    func testBatterySymbolAndKeepAwakeWords() {
        XCTAssertEqual(AgentsMacPowerCopy.batterySymbol(level: 29, charging: false), "battery.25percent")
        XCTAssertEqual(AgentsMacPowerCopy.batterySymbol(level: 5, charging: false), "battery.0percent")
        XCTAssertEqual(AgentsMacPowerCopy.batterySymbol(level: 100, charging: false), "battery.100percent")
        XCTAssertEqual(AgentsMacPowerCopy.batterySymbol(level: 29, charging: true), "battery.100percent.bolt")
        // the server turns Keep awake off after KEEP_AWAKE_MAX: both states say so
        XCTAssertTrue(AgentsMacPowerCopy.keepAwakeSubtitle(on: true).contains("12 hours"))
        XCTAssertTrue(AgentsMacPowerCopy.keepAwakeSubtitle(on: false).contains("12 hours"))
    }

    // MARK: the password sheet's queue

    private func request(_ id: String, expires: Double) -> MacPasswordRequest {
        MacPasswordRequest(json: ["id": id, "device_id": "mac-1", "kind": "sudo", "context": "x",
                                  "nonce": "n", "expires": expires])
    }

    func testThePasswordSheetShowsOneAtATimeAndSkipsSnoozedAndExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = request("a", expires: 1_700_000_100), b = request("b", expires: 1_700_000_100)
        let old = request("old", expires: 1_699_999_990)
        XCTAssertEqual(MacPasswordQueue.next([old, a, b], snoozed: [], now: now)?.id, "a")
        XCTAssertEqual(MacPasswordQueue.next([a, b], snoozed: ["a"], now: now)?.id, "b")
        XCTAssertNil(MacPasswordQueue.next([a], snoozed: ["a"], now: now))
        XCTAssertFalse(MacPasswordQueue.isDone(a, in: [a, b], now: now))
        XCTAssertTrue(MacPasswordQueue.isDone(a, in: [b], now: now), "answered: it left the list")
        XCTAssertTrue(MacPasswordQueue.isDone(a, in: [a], now: Date(timeIntervalSince1970: 1_700_000_100)))
    }

    func testRequestsNameTheirMacFriendly() throws {
        let macs = [AgentMacPower(json: ["device_id": "mac-1", "name": "Pranavs-MacBook-Pro.local"])]
        XCTAssertEqual(AgentsMacPowerCopy.macName("mac-1", in: macs), "Pranav's MacBook Pro")
        XCTAssertEqual(AgentsMacPowerCopy.macName("gone", in: macs), "Your Mac")
    }

    // MARK: the signed yes

    func testSignedMessageBytes() {
        // the same bytes the Mac's ApprovalVerifier.message builds (MacPasswordTests.testMessageFormat)
        let data = MacPasswordApproval.message(kind: "sudo", nonce: "abc123", ts: 1_700_000_000, context: "hi")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "jarvis-mac-password|sudo|abc123|1700000000|8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")
    }

    func testSheetTitlesAndCountdown() {
        XCTAssertEqual(MacPasswordSheetCopy.title(kind: "sudo"), "sudo wants your Mac password")
        XCTAssertEqual(MacPasswordSheetCopy.title(kind: "admin"), "Admin access on your Mac")
        XCTAssertEqual(MacPasswordSheetCopy.title(kind: "keychain"), "Keychain access")
        XCTAssertEqual(MacPasswordSheetCopy.title(kind: "unlock"), "Unlock your Mac")
        XCTAssertEqual(MacPasswordSheetCopy.title(kind: "something-new"), "Your Mac wants its password")
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

/// The MacBook card (awake, asleep, waking) and the password sheet, drawn to
/// /tmp/ringshots to look at before installing.
@MainActor
final class AgentsMacPowerRenderTests: XCTestCase {
    private func store(_ macs: [[String: Any]]) -> AgentsStore {
        let store = AgentsStore(api: AgentsAPI(api: JarvisAPI.mocked().0), topics: BridgeTopics())
        store.show(AgentsList(json: ["needs_you": [], "projects": [], "mac": macs]))
        return store
    }

    func testTheMacBookCardRenders() throws {
        let now = Date().timeIntervalSince1970
        let awake: [String: Any] = ["device_id": "mac-1", "name": "Pranavs-MacBook-Pro.local", "state": "awake",
                                    "held": true, "reason": "session", "keep_awake": false, "timer_on": true,
                                    "battery": 29, "on_ac": false, "lid": "open", "seen_at": now]
        let asleep: [String: Any] = ["device_id": "mac-2", "name": "Pranavs-MacBook-Air.local", "state": "sleeping",
                                     "keep_awake": true, "battery": 84, "on_ac": true, "seen_at": now - 300]
        let waking: [String: Any] = ["device_id": "mac-3", "name": "Studio-Mac-mini.local", "state": "sleeping",
                                     "seen_at": now - 7200, "wake_requested_at": now - 90]
        let store = store([awake, asleep, waking])
        let page = ScrollView {
            VStack(spacing: 12) {
                ForEach(store.macs) { AgentsMacPowerCard(mac: $0, store: store) }
                JcCard(padding: 0) {
                    AgentsMacPasswordRow(request: MacPasswordRequest(json: [
                        "id": "pw", "device_id": "mac-1", "kind": "sudo", "context": "x", "nonce": "n",
                        "expires": now + 102]), macName: "Pranav's MacBook Pro", last: true) {}
                }
            }
            .padding(16)
        }
        try RenderHarness.write(page, size: CGSize(width: 402, height: 874), name: "agents-mac-card")
    }

    func testThePasswordSheetRenders() throws {
        let now = Date().timeIntervalSince1970
        let short = MacPasswordRequest(json: [
            "id": "pw-1", "device_id": "mac-1", "kind": "sudo", "nonce": "n", "expires": now + 102,
            "context": "sudo in jarvis-copilot: brew install jq"])
        let long = MacPasswordRequest(json: [
            "id": "pw-2", "device_id": "mac-1", "kind": "admin", "nonce": "n", "expires": now + 24,
            "context": (1...14).map { "line \($0): installer wants to change /Library/LaunchDaemons/com.example.helper.plist" }
                .joined(separator: "\n")])
        for (request, name) in [(short, "mac-password-sheet"), (long, "mac-password-sheet-long")] {
            let host = Color.black.sheet(isPresented: .constant(true)) {
                MacPasswordSheet(request: request, macName: "Pranav's MacBook Pro", answer: { _ in nil })
            }
            try RenderHarness.write(host, size: CGSize(width: 402, height: 874), name: name, settle: 3)
        }
    }
}
