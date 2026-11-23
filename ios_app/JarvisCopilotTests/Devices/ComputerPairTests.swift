import CryptoKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

// Pairing a computer by scanning its QR (docs/superpowers/plans/2026-11-23-qr-pairing.md):
// the QR's URL, the AES-256-GCM hand-off body jc-client opens, and the sheet's flow.

/// Bytes 0…31 as the QR key, written the way jc-client writes it: base64url, no padding.
private let testKey = Data(0..<32)
private let testKeyText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

private func qr(host: String = "192.168.1.20", port: String = "53111", key: String = testKeyText,
                name: String = "Gaming%20PC", os: String = "windows", v: String = "1") -> String {
    "jarvis://pair-computer?v=\(v)&host=\(host)&port=\(port)&key=\(key)&name=\(name)&os=\(os)"
}

/// Opens a hand-off body the way jc-client does — base64 nonce, base64 ciphertext‖tag and the
/// contract's AAD, spelled out here rather than read from the app so the test pins the contract.
private func openBody(_ body: Data, key: Data = testKey,
                      aad: Data = Data("jarvis-pair-computer-v1".utf8)) throws -> [String: Any] {
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let nonce = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["nonce"] as? String)))
    let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["ct"] as? String)))
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                    ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
    let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
}

// MARK: - The QR

final class ComputerPairPayloadTests: XCTestCase {

    func testParsesAWindowsQR() throws {
        let payload = try XCTUnwrap(ComputerPairPayload.parse(qr()))
        XCTAssertEqual(payload.host, "192.168.1.20")
        XCTAssertEqual(payload.port, 53111)
        XCTAssertEqual(payload.key, testKey)
        XCTAssertEqual(payload.name, "Gaming PC")
        XCTAssertEqual(payload.os, .windows)
        XCTAssertEqual(payload.os.label, "Windows")
        XCTAssertEqual(payload.pairURL.absoluteString, "http://192.168.1.20:53111/pair")
        XCTAssertEqual(payload.title, "Pair Gaming PC (Windows)?")
    }

    /// Python's urlencode writes a space as "+"; a real "+" would arrive as %2B.
    func testParsesAMacQRWithAFormEncodedName() throws {
        let payload = try XCTUnwrap(ComputerPairPayload.parse(
            "  " + qr(name: "Pranav%E2%80%99s+MacBook+%2B1", os: "macos") + "\n"))
        XCTAssertEqual(payload.name, "Pranav\u{2019}s MacBook +1")
        XCTAssertEqual(payload.os, .macos)
        XCTAssertEqual(payload.title, "Pair Pranav\u{2019}s MacBook +1 (Mac)?")
    }

    func testTheKeyIsBase64URL() throws {
        let key = Data(repeating: 0xFB, count: 32)   // "+/v7…" in plain base64
        let text = key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertTrue(text.contains("-") && text.contains("_"))
        XCTAssertEqual(ComputerPairPayload.parse(qr(key: text))?.key, key)
    }

    func testRejectsWhatIsNotAComputerPairLink() {
        let short = Data(0..<31).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let rejected = [
            "",
            "hello",
            qr().replacingOccurrences(of: "jarvis://", with: "jarviscopilot://"),
            qr().replacingOccurrences(of: "pair-computer", with: "pair"),
            qr(v: "2"),
            qr().replacingOccurrences(of: "v=1&", with: ""),
            qr(key: short),
            qr(key: "not-a-key!!"),
            qr(port: "0"),
            qr(port: "65536"),
            qr(port: "http"),
            qr(host: "jarvis.example.com"),
            qr(host: "192.168.1"),
            qr(host: "192.168.1.256"),
            qr(os: "linux"),
            qr(name: ""),
            qr(name: "%20%20"),
            "jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=Jarvis-64D5&pw=ABCDEFGHJKMN&id=240ac41264d5",
        ]
        for raw in rejected {
            XCTAssertNil(ComputerPairPayload.parse(raw), raw)
        }
    }

    /// The code goes to whatever address the QR names, so only home-network addresses
    /// (and Tailscale's 100.64/10) are taken — never one out on the internet.
    func testOnlyHomeNetworkAddressesAreAccepted() {
        for host in ["10.0.0.5", "172.16.4.2", "172.31.255.1", "192.168.0.1", "169.254.10.2", "100.101.102.103"] {
            XCTAssertNotNil(ComputerPairPayload.parse(qr(host: host)), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.1.1.1", "192.169.0.1"] {
            XCTAssertNil(ComputerPairPayload.parse(qr(host: host)), host)
        }
    }

    /// The Devices page's one camera takes both a Jarvis Pod's setup code and a computer's QR.
    func testTheDeviceScannerTellsPodsFromComputers() throws {
        let pod = "jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=Jarvis-64D5&pw=ABCDEFGHJKMN&id=240ac41264d5"
        XCTAssertEqual(DeviceScanCode.parse(pod), .pod(try XCTUnwrap(PodSetupCode.parse(pod))))
        XCTAssertEqual(DeviceScanCode.parse(qr()), .computer(try XCTUnwrap(ComputerPairPayload.parse(qr()))))
        XCTAssertNil(DeviceScanCode.parse("https://example.com"))
    }
}

// MARK: - The sealed hand-off

final class ComputerPairSealTests: XCTestCase {

    private let plaintext = Data(#"{"code":"ABC-DEF","server":"https://jarvis.test"}"#.utf8)

    func testThePlaintextCarriesTheContractFields() throws {
        let data = ComputerPairSeal.plaintext(server: "https://jarvis.test", code: "ABC-DEF",
                                              cfID: "cid", cfSecret: "csec", ts: 1_800_000_000)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["server", "code", "cf_id", "cf_secret", "ts"])
        XCTAssertEqual(object["server"] as? String, "https://jarvis.test")
        XCTAssertEqual(object["code"] as? String, "ABC-DEF")
        XCTAssertEqual(object["cf_id"] as? String, "cid")
        XCTAssertEqual(object["cf_secret"] as? String, "csec")
        XCTAssertEqual(object["ts"] as? Int, 1_800_000_000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("1800000000."), "ts is whole seconds")
    }

    func testTheBodyIsVersionNonceAndCiphertextWithItsTag() throws {
        let body = try ComputerPairSeal.body(sealing: plaintext, key: testKey)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "nonce", "ct"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(Data(base64Encoded: object["nonce"] as? String ?? "")?.count, 12)
        XCTAssertEqual(Data(base64Encoded: object["ct"] as? String ?? "")?.count, plaintext.count + 16)
    }

    func testItsOwnOutputOpensWithTheQRKeyAndTheAAD() throws {
        let body = try ComputerPairSeal.body(sealing: plaintext, key: testKey)
        let opened = try openBody(body)
        XCTAssertEqual(opened["code"] as? String, "ABC-DEF")
        XCTAssertEqual(opened["server"] as? String, "https://jarvis.test")
    }

    func testAnotherKeyOrAnotherAADCannotOpenIt() throws {
        let body = try ComputerPairSeal.body(sealing: plaintext, key: testKey)
        XCTAssertThrowsError(try openBody(body, key: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try openBody(body, aad: Data("jarvis-pair-computer-v2".utf8)))
        XCTAssertThrowsError(try openBody(body, aad: Data()))
    }

    /// Known answer from Python's cryptography (jc-client's library):
    /// AESGCM(bytes(range(32))).encrypt(bytes(range(12)), plaintext, b"jarvis-pair-computer-v1").
    func testMatchesPythonCryptographyByteForByte() throws {
        let body = try ComputerPairSeal.body(sealing: plaintext, key: testKey, nonce: Data(0..<12))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["nonce"] as? String, "AAECAwQFBgcICQoL")
        XCTAssertEqual(object["ct"] as? String,
                       "PCC1dKGA4CGvANXInK09K6H6pUeVCSkZSkXfp3UddMJyKoHTxaBg7h3XUZnt9Fwak4FqTH5isuDgpABcxl1f3Rk=")
    }

    /// jc-client refuses a nonce it has seen, so a retry must never reuse one.
    func testEverySealUsesAFreshNonce() throws {
        let nonces = try (0..<5).map { _ -> String in
            let body = try ComputerPairSeal.body(sealing: plaintext, key: testKey)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return object?["nonce"] as? String ?? ""
        }
        XCTAssertEqual(Set(nonces).count, 5)
    }

    func testOnlyA32ByteKeySeals() {
        XCTAssertThrowsError(try ComputerPairSeal.body(sealing: plaintext, key: Data(0..<16)))
    }
}

// MARK: - The flow behind the sheet

/// The computer's /pair listener, scripted.
private final class FakeComputer: ComputerPairSending, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<String, ComputerPairSendError>]
    private var _bodies: [Data] = []
    private var _urls: [URL] = []

    init(_ outcomes: Result<String, ComputerPairSendError>...) { self.outcomes = outcomes }

    var bodies: [Data] { lock.withLock { _bodies } }
    var urls: [URL] { lock.withLock { _urls } }

    func send(_ body: Data, to url: URL) async throws -> String {
        let outcome: Result<String, ComputerPairSendError> = lock.withLock {
            _bodies.append(body)
            _urls.append(url)
            return outcomes.isEmpty ? .success("") : outcomes.removeFirst()
        }
        return try outcome.get()
    }
}

@MainActor
final class ComputerPairFlowTests: XCTestCase {

    private let payload = ComputerPairPayload.parse(qr())!
    private var reasons: [String] = []

    private func makeFlow(_ computer: FakeComputer, faceID: Bool = true,
                          start: Any = ["code": "ABC-DEF", "expires_at": 1_800_000_600,
                                        "cf_access": ["client_id": "cid", "client_secret": "csec"]],
                          startStatus: Int = 200) -> (ComputerPairFlow, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/pair/start", json: start, status: startStatus)
        let flow = ComputerPairFlow(payload: payload, api: DevicesAPI(api: api), sender: computer,
                                    confirmOwner: { [weak self] reason in
                                        self?.reasons.append(reason)
                                        return faceID
                                    },
                                    now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (flow, transport)
    }

    func testHappyPathPairsAfterFaceIDWithASealedCode() async throws {
        let computer = FakeComputer(.success("GAMING-PC"))
        let (flow, transport) = makeFlow(computer)
        XCTAssertEqual(flow.phase, .confirm)

        await flow.pair()

        XCTAssertEqual(flow.phase, .paired("GAMING-PC"))
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("Gaming PC"), reasons[0])
        // The code is asked for under the computer's name, for the usual ten minutes.
        let start = transport.lastBody()
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/devices/pair/start")
        XCTAssertEqual(start["label"] as? String, "Gaming PC")
        XCTAssertEqual(start["ttl"] as? Int, 600)
        // …and goes to the address in the QR, sealed with its key.
        XCTAssertEqual(computer.urls, [URL(string: "http://192.168.1.20:53111/pair")!])
        let sent = try openBody(try XCTUnwrap(computer.bodies.first))
        XCTAssertEqual(sent["server"] as? String, "https://jarvis.test")
        XCTAssertEqual(sent["code"] as? String, "ABC-DEF")
        XCTAssertEqual(sent["cf_id"] as? String, "cid")
        XCTAssertEqual(sent["cf_secret"] as? String, "csec")
        XCTAssertEqual(sent["ts"] as? Int, 1_800_000_000)
    }

    func testAComputerThatGivesNoNameIsCalledWhatTheQRSaid() async {
        let (flow, _) = makeFlow(FakeComputer(.success("")))
        await flow.pair()
        XCTAssertEqual(flow.phase, .paired("Gaming PC"))
    }

    func testAServerWithoutCloudflareSendsEmptyTokens() async throws {
        let computer = FakeComputer(.success("PC"))
        let (flow, _) = makeFlow(computer, start: ["code": "ABC-DEF"])
        await flow.pair()
        let sent = try openBody(try XCTUnwrap(computer.bodies.first))
        XCTAssertEqual(sent["cf_id"] as? String, "")
        XCTAssertEqual(sent["cf_secret"] as? String, "")
    }

    func testNoFaceIDNoCode() async {
        let computer = FakeComputer()
        let (flow, transport) = makeFlow(computer, faceID: false)
        await flow.pair()
        XCTAssertEqual(flow.phase, .confirm)
        XCTAssertNotNil(flow.notice)
        XCTAssertTrue(transport.requests.isEmpty, "no pairing code without Face ID")
        XCTAssertTrue(computer.bodies.isEmpty)
    }

    func testAnUnreachableComputerFallsBackToTheCode() async {
        let (flow, _) = makeFlow(FakeComputer(.failure(.unreachable("timed out"))))
        await flow.pair()
        XCTAssertEqual(flow.phase, .fallback(code: "ABC-DEF", error: nil))
        XCTAssertEqual(flow.fallbackMessage,
                       "Your phone can't reach the computer \u{2014} type this code on it: ABC-DEF")
        XCTAssertTrue(flow.canRetrySend)
    }

    func testARefusalShowsTheComputersErrorAndTheCode() async {
        let (flow, _) = makeFlow(FakeComputer(.failure(.rejected(status: 409, message: "used or expired"))))
        await flow.pair()
        XCTAssertEqual(flow.phase, .fallback(code: "ABC-DEF", error: "used or expired"))
        let message = flow.fallbackMessage ?? ""
        XCTAssertTrue(message.contains("used or expired"), message)
        XCTAssertTrue(message.hasSuffix("type this code on it: ABC-DEF"), message)
        XCTAssertFalse(flow.canRetrySend, "the listener is spent; sending again can't help")
    }

    /// The first send can lose to iOS's local-network prompt. "Try again" re-seals the same code
    /// (no second code, no second Face ID) under a fresh nonce.
    func testTryAgainResendsTheSameCodeUnderAFreshNonce() async throws {
        let computer = FakeComputer(.failure(.unreachable("offline")), .success("PC"))
        let (flow, transport) = makeFlow(computer)
        await flow.pair()
        await flow.retrySend()

        XCTAssertEqual(flow.phase, .paired("PC"))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(computer.bodies.count, 2)
        let nonces = try computer.bodies.map { body -> String in
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return object?["nonce"] as? String ?? ""
        }
        XCTAssertNotEqual(nonces[0], nonces[1])
        XCTAssertEqual(try openBody(computer.bodies[1])["code"] as? String, "ABC-DEF")
    }

    func testNoCodeFromTheServerIsAnErrorNotAHandOff() async {
        let computer = FakeComputer()
        let (flow, _) = makeFlow(computer, start: ["error": "boom"], startStatus: 500)
        await flow.pair()
        guard case .failed(let message) = flow.phase else { return XCTFail("expected failed, got \(flow.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(computer.bodies.isEmpty)
    }

    // MARK: The computer's reply

    func testTheComputersReplyIsRead() throws {
        func reply(_ json: String, _ status: Int) throws -> String {
            try ComputerPairHTTP.reply(data: Data(json.utf8), status: status)
        }
        XCTAssertEqual(try reply(#"{"ok":true,"device_name":"GAMING-PC"}"#, 200), "GAMING-PC")
        XCTAssertEqual(try reply(#"{"ok":true}"#, 200), "")
        XCTAssertThrowsError(try reply(#"{"ok":false,"error":"bad key"}"#, 401)) {
            XCTAssertEqual($0 as? ComputerPairSendError, .rejected(status: 401, message: "bad key"))
        }
        XCTAssertThrowsError(try reply(#"{"ok":false,"error":"used"}"#, 200)) {
            XCTAssertEqual($0 as? ComputerPairSendError, .rejected(status: 200, message: "used"))
        }
        XCTAssertThrowsError(try reply("Bad Gateway", 502)) {
            XCTAssertEqual($0 as? ComputerPairSendError, .rejected(status: 502, message: "HTTP 502"))
        }
    }

    // MARK: Rendering

    func testTheSheetRendersInEveryState() async {
        let (confirm, _) = makeFlow(FakeComputer())
        moreUIBHost(ComputerPairSheet(flow: confirm))

        let (fallback, _) = makeFlow(FakeComputer(.failure(.unreachable("offline"))))
        await fallback.pair()
        moreUIBHost(ComputerPairSheet(flow: fallback))

        let (paired, _) = makeFlow(FakeComputer(.success("PC")))
        await paired.pair()
        moreUIBHost(ComputerPairSheet(flow: paired))
    }

    func testTheServerHalfOffersAddComputer() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: MoreUIBFixtures.deviceSkills)
        transport.route("/api/devices", json: MoreUIBFixtures.devices)
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        var opened = false
        let section = DevicesServerSection(store: store, onAddComputer: { opened = true })
        moreUIBHost(section)
        section.onAddComputer?()
        XCTAssertTrue(opened)
    }
}
