import XCTest
@testable import JarvisCopilot

/// Ports the QR-payload cases from the Flutter client's `pair_page.dart`
/// `_handleScan` so the same QR keeps working in both apps.
final class PairPayloadTests: XCTestCase {

    // MARK: Case 1 — the jarviscopilot:// deep link

    func testDeepLinkCarriesServerCodeAndCloudflareToken() {
        let payload = PairingPayload(
            raw: "jarviscopilot://pair?server=https://1.2.3.4:8787&code=ABC-DEF"
               + "&cf_id=xxxx.access&cf_secret=s3cret")
        XCTAssertEqual(payload?.server, "https://1.2.3.4:8787")
        XCTAssertEqual(payload?.code, "ABC-DEF")
        XCTAssertEqual(payload?.cfClientID, "xxxx.access")
        XCTAssertEqual(payload?.cfClientSecret, "s3cret")
    }

    func testDeepLinkWithoutCloudflareTokenLeavesItNil() {
        let payload = PairingPayload(raw: "jarviscopilot://pair?server=https://jarvis.test&code=XYZ")
        XCTAssertEqual(payload?.server, "https://jarvis.test")
        XCTAssertEqual(payload?.code, "XYZ")
        XCTAssertNil(payload?.cfClientID)
        XCTAssertNil(payload?.cfClientSecret)
    }

    func testDeepLinkWithOnlyACodeIsAccepted() {
        let payload = PairingPayload(raw: "jarviscopilot://pair?code=ABC123")
        XCTAssertEqual(payload?.code, "ABC123")
        XCTAssertNil(payload?.server)
    }

    /// Forward-compatible extra the webui may add for on-LAN shortcuts. Absent
    /// from every QR the Flutter client can produce today, so it must stay optional.
    func testDeepLinkCarriesOptionalLanURL() {
        let payload = PairingPayload(
            raw: "jarviscopilot://pair?server=https://jarvis.test&lan_url=https://10.0.0.9:8787&code=Q")
        XCTAssertEqual(payload?.lanURL, "https://10.0.0.9:8787")
        XCTAssertEqual(payload?.server, "https://jarvis.test")
    }

    func testDeepLinkWithNeitherServerNorCodeIsRejected() {
        XCTAssertNil(PairingPayload(raw: "jarviscopilot://pair"))
    }

    // MARK: Case 2/3 — a plain server URL (the `/pair` path is dropped)

    func testHttpsPairURLKeepsSchemeAndAuthorityAndDropsThePath() {
        let payload = PairingPayload(raw: "https://jarvis.example.com/pair")
        XCTAssertEqual(payload?.server, "https://jarvis.example.com")
        XCTAssertNil(payload?.code)
    }

    func testHttpsPairURLKeepsAnExplicitPort() {
        let payload = PairingPayload(raw: "https://10.0.0.9:8787/pair")
        XCTAssertEqual(payload?.server, "https://10.0.0.9:8787")
    }

    func testBareHttpsURLIsUsedAsTheServer() {
        XCTAssertEqual(PairingPayload(raw: "https://jarvis.example.com")?.server,
                       "https://jarvis.example.com")
    }

    /// The session cookie the claim returns IS the credential and a QR can carry
    /// a Cloudflare service token, so plain http is refused at parse time — the
    /// legacy settings screen has no https gate of its own, and a QR is exactly
    /// where the user can't read the URL they are agreeing to.
    func testHttpURLIsRejected() {
        XCTAssertNil(PairingPayload(raw: "http://192.168.1.5:8787"))
        XCTAssertNil(PairingPayload(raw: "http://jarvis.example.com/pair"))
    }

    func testADeepLinkNamingAnHttpServerIsRejected() {
        XCTAssertNil(PairingPayload(raw: "jarviscopilot://pair?server=http://1.2.3.4:8787&code=A"))
        XCTAssertNil(PairingPayload(raw: "jarviscopilot://pair?server=HTTP://1.2.3.4&code=A"))
        // …including via the LAN shortcut, which is applied the same way.
        XCTAssertNil(PairingPayload(
            raw: "jarviscopilot://pair?server=https://a.test&lan_url=http://10.0.0.9&code=A"))
    }

    // MARK: Rejected

    func testUnrecognisedPayloadsAreRejected() {
        XCTAssertNil(PairingPayload(raw: ""), "empty")
        XCTAssertNil(PairingPayload(raw: "   "), "whitespace")
        XCTAssertNil(PairingPayload(raw: "ABC123"), "a bare code is not a link")
        XCTAssertNil(PairingPayload(raw: "WIFI:S:home;T:WPA;P:hunter2;;"), "a wifi QR")
        XCTAssertNil(PairingPayload(raw: "jarviscopilot://voice"), "wrong host")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(PairingPayload(raw: "  https://jarvis.test\n")?.server,
                       "https://jarvis.test")
    }

    // MARK: the confirmation the legacy settings screen shows

    /// Scanning used to pair outright. The prompt has to name the host, because
    /// that is the whole thing the user is being asked to trust.
    func testTheConfirmationNamesTheHost() throws {
        let payload = try XCTUnwrap(
            PairingPayload(raw: "jarviscopilot://pair?server=https://jarvis.test:8787&code=ABC"))
        let confirm = BridgePairConfirmation(payload)
        XCTAssertEqual(confirm.title, "Pair with jarvis.test?")
        XCTAssertTrue(confirm.message.contains("jarvis.test"), confirm.message)
        XCTAssertTrue(confirm.message.contains("pairing code came from the QR"), confirm.message)
        XCTAssertFalse(confirm.message.contains("Cloudflare"), confirm.message)
    }

    func testTheConfirmationCallsOutAStoredCloudflareToken() throws {
        let payload = try XCTUnwrap(PairingPayload(
            raw: "jarviscopilot://pair?server=https://jarvis.test&code=A&cf_id=x.access&cf_secret=s"))
        let confirm = BridgePairConfirmation(payload)
        XCTAssertTrue(confirm.message.contains("Cloudflare Access token"), confirm.message)
    }

    func testTheConfirmationFallsBackWhenThereIsNoServer() throws {
        let payload = try XCTUnwrap(PairingPayload(raw: "jarviscopilot://pair?code=ABC123"))
        XCTAssertEqual(BridgePairConfirmation(payload).title, "Pair with this server?")
    }
}
