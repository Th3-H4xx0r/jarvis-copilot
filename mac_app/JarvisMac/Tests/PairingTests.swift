import CoreImage
import XCTest
@testable import Jarvis

/// "Pair with your iPhone" on the Mac (contract: docs/superpowers/plans/2026-11-23-qr-pairing.md):
/// pair_status → pair_qr_start → a QR with a countdown that renews itself, pair_state broadcasts,
/// and "Type a code instead" (pair_manual). Mirrors the Windows app's PairFlow tests.
@MainActor
final class PairingTests: XCTestCase {
    private let payload1 = "jarvis://pair-computer?v=1&host=192.168.1.40&port=47913&key=AAAA&name=Pranav%27s%20Mac&os=macos"
    private let payload2 = "jarvis://pair-computer?v=1&host=192.168.1.40&port=47913&key=BBBB&name=Pranav%27s%20Mac&os=macos"

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var link: FakePairLink!
    private var flow: PairFlow!
    private var payloads: [String] = []
    private var status: [String: Any] = [:]
    private var qrFailure: [String: Any]?
    private var manualReply: [String: Any] = ["ok": true]
    private var ttl: Double = 600

    override func setUp() async throws {
        payloads = [payload1, payload2, payload1 + "3", payload1 + "4"]
        status = ["ok": true, "paired": false, "server": "https://jarvis.example.com", "device_name": "Pranav's Mac"]
        link = FakePairLink()
        link.reply = { [unowned self] body in
            switch body["type"] as? String {
            case "pair_status": return self.status
            case "pair_qr_start":
                if let f = self.qrFailure { return f }
                return ["ok": true, "payload": self.payloads.isEmpty ? "jarvis://pair-computer?v=1" : self.payloads.removeFirst(),
                        "expires_at": self.now.timeIntervalSince1970 + self.ttl, "host": "192.168.1.40", "port": 47913]
            case "pair_manual": return self.manualReply
            default: return ["ok": false, "error": "unexpected"]
            }
        }
        flow = PairFlow(link: link, clock: { [unowned self] in self.now })
    }

    private var qrStarts: Int { link.sent(ofType: "pair_qr_start").count }

    private func advance(_ seconds: Double) {
        // The window ticks once a second.
        for _ in 0..<Int(seconds) {
            now = now.addingTimeInterval(1)
            flow.tick()
        }
    }

    private func state(_ s: String, deviceName: String? = nil, error: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["type": "pair_state", "state": s]
        if let deviceName { m["device_name"] = deviceName }
        if let error { m["error"] = error }
        return m
    }

    // MARK: when the screen shows itself

    func testNeedsPairingOnlyWhenJcClientSaysUnpaired() {
        XCTAssertTrue(PairFlow.needsPairing(["ok": true, "paired": false, "server": "", "device_name": ""]))
        XCTAssertFalse(PairFlow.needsPairing(["ok": true, "paired": true, "server": "https://j.example"]))
        XCTAssertFalse(PairFlow.needsPairing(["ok": false, "error": "unknown request 'pair_status'"]))
        XCTAssertFalse(PairFlow.needsPairing(["ok": false, "error": "Jarvis isn't running on this Mac"]))
        XCTAssertFalse(PairFlow.needsPairing(["ok": true]))
    }

    func testHelloAsksPairStatus_AndAnUnpairedMacOpensTheScreen() {
        let model = AppModel()
        var opened = 0
        model.onNeedsPairing = { opened += 1 }
        model.checkPairing(link: link)
        XCTAssertEqual(link.sent.map { $0["type"] as? String }, ["pair_status"])
        XCTAssertEqual(opened, 1)
        status = ["ok": true, "paired": true, "server": "https://jarvis.example.com"]
        model.checkPairing(link: link)
        XCTAssertEqual(opened, 1)
    }

    func testPairStateBroadcastsArePassedOn() {
        let model = AppModel()
        var got: [String: Any]?
        model.onPairState = { got = $0 }
        model.handle(state("paired", deviceName: "Pranav's Mac"))
        XCTAssertEqual(got?["state"] as? String, "paired")
        XCTAssertEqual(got?["device_name"] as? String, "Pranav's Mac")
    }

    // MARK: the QR and its countdown

    func testOpenShowsTheQrFromPairQrStartWithItsCountdown() {
        flow.open()
        XCTAssertEqual(link.sent.map { $0["type"] as? String }, ["pair_status", "pair_qr_start"])
        XCTAssertEqual(link.sent[1].count, 1, "pair_qr_start carries nothing else")
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertEqual(flow.payload, payload1)
        XCTAssertEqual(flow.host, "192.168.1.40")
        XCTAssertEqual(flow.port, 47913)
        XCTAssertEqual(flow.secondsLeft, 600)
        XCTAssertEqual(flow.countdown, "10:00")
        XCTAssertEqual(flow.server, "https://jarvis.example.com")
        XCTAssertEqual(flow.deviceName, "Pranav's Mac")
    }

    func testCountdownTicks() {
        flow.open()
        advance(3)
        XCTAssertEqual(flow.secondsLeft, 597)
        XCTAssertEqual(flow.countdown, "9:57")
    }

    func testAtExpiryANewCodeReplacesTheOldOne() {
        flow.open()
        advance(599)
        XCTAssertEqual(qrStarts, 1)
        advance(1)
        XCTAssertEqual(qrStarts, 2)
        XCTAssertEqual(flow.payload, payload2)
        XCTAssertEqual(flow.secondsLeft, 600)
        XCTAssertEqual(flow.stage, .waiting)
    }

    func testExpiredBroadcastRenewsOnceEvenIfTheTimerAgrees() {
        flow.open()
        advance(600)
        flow.handle(state("expired"))
        XCTAssertEqual(qrStarts, 2)
    }

    func testExpiredBroadcastRenewsTheCode() {
        flow.open()
        advance(30)
        flow.handle(state("expired"))
        XCTAssertEqual(qrStarts, 2)
        XCTAssertEqual(flow.payload, payload2)
    }

    func testACodeWithNoExpiryIsNeverRenewedInALoop() {
        ttl = -5
        flow.open()
        advance(10)
        XCTAssertEqual(qrStarts, 1)
        XCTAssertEqual(flow.countdown, "")
    }

    // MARK: live state from jc-client

    func testPairingThenPaired() {
        flow.open()
        flow.handle(state("pairing"))
        XCTAssertEqual(flow.stage, .pairing)
        advance(700)
        XCTAssertEqual(qrStarts, 1, "no new code mid-claim")
        flow.handle(state("paired", deviceName: "Studio Mac"))
        XCTAssertEqual(flow.stage, .paired)
        XCTAssertEqual(flow.isPaired, true)
        XCTAssertEqual(flow.deviceName, "Studio Mac")
    }

    func testErrorBroadcastShowsItAndANewCodeRecovers() {
        flow.open()
        flow.handle(state("error", error: "the server refused the code"))
        XCTAssertEqual(flow.stage, .failed)
        XCTAssertEqual(flow.error, "the server refused the code")
        advance(700)
        XCTAssertEqual(qrStarts, 1, "a failed screen waits for him")
        flow.newCode()
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.payload, payload2)
    }

    func testWaitingBroadcastAfterAFailedClaimShowsTheCodeAgain() {
        flow.open()
        flow.handle(state("pairing"))
        flow.handle(state("waiting"))
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertEqual(flow.payload, payload1)
    }

    func testQrStartFailureIsShown() {
        qrFailure = ["ok": false, "error": "no network address for the phone to reach"]
        flow.open()
        XCTAssertEqual(flow.stage, .failed)
        XCTAssertEqual(flow.error, "no network address for the phone to reach")
        XCTAssertNil(flow.payload)
    }

    func testAnOlderJcClientSaysToUpdateIt() {
        qrFailure = ["ok": false, "error": "unknown request 'pair_qr_start'"]
        flow.open()
        XCTAssertEqual(flow.error, PairFlow.oldClientError)
    }

    func testClosedScreenIgnoresLateRepliesAndOpensNoListener() {
        link.hold = true
        flow.open()
        flow.close()
        link.release()
        XCTAssertEqual(qrStarts, 0)
        XCTAssertNil(flow.payload)
        flow.handle(state("expired"))
        advance(700)
        XCTAssertEqual(qrStarts, 0)
    }

    // MARK: "Type a code instead"

    func testManualServerIsPrefilledFromPairStatusNeverALanDefault() {
        status = ["ok": true, "paired": false, "server": "", "device_name": ""]
        flow.open()
        XCTAssertEqual(flow.server, "")
    }

    func testManualSendsPairManualTrimmedWithoutEmptyCloudflareFields() {
        flow.open()
        XCTAssertTrue(flow.manual(server: "  https://jarvis.example.com  ", code: " ABC-123 "))
        let sent = link.sent(ofType: "pair_manual")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["server"] as? String, "https://jarvis.example.com")
        XCTAssertEqual(sent[0]["code"] as? String, "ABC-123")
        XCTAssertNil(sent[0]["cf_id"])
        XCTAssertNil(sent[0]["cf_secret"])
        XCTAssertEqual(flow.stage, .paired)
        XCTAssertEqual(flow.isPaired, true)
    }

    func testManualPassesTheCloudflareTokenWhenGiven() {
        flow.open()
        flow.manual(server: "https://jarvis.example.com", code: "ABC-123", cfId: " id.access ", cfSecret: " s3cret ")
        let sent = link.sent(ofType: "pair_manual")[0]
        XCTAssertEqual(sent["cf_id"] as? String, "id.access")
        XCTAssertEqual(sent["cf_secret"] as? String, "s3cret")
    }

    func testManualShowsJcClientsError() {
        manualReply = ["ok": false, "error": "HTTP 404 — code not found"]
        flow.open()
        flow.manual(server: "https://jarvis.example.com", code: "ABC-123")
        XCTAssertEqual(flow.manualError, "HTTP 404 — code not found")
        XCTAssertEqual(flow.stage, .waiting, "the QR stays up beside the form")
        XCTAssertFalse(flow.manualBusy)
    }

    func testManualChecksWhatHeTypedBeforeAsking() {
        flow.open()
        for (server, code, error) in [("", "ABC-123", "Type your Jarvis server's address."),
                                      ("jarvis.example.com", "ABC-123", "The address starts with https:// (or http://)."),
                                      ("https://jarvis.example.com", "  ", "Type the code your iPhone shows.")] {
            XCTAssertFalse(flow.manual(server: server, code: code))
            XCTAssertEqual(flow.manualError, error)
        }
        XCTAssertTrue(link.sent(ofType: "pair_manual").isEmpty)
    }

    func testCountdownFormatAndSettingsSummary() {
        XCTAssertEqual(PairFlow.format(600), "10:00")
        XCTAssertEqual(PairFlow.format(61), "1:01")
        XCTAssertEqual(PairFlow.format(9), "0:09")
        XCTAssertEqual(PairFlow.summary(paired: true, server: "https://jarvis.example.com:8787/"), "Paired with jarvis.example.com")
        XCTAssertEqual(PairFlow.summary(paired: true, server: ""), "Paired")
        XCTAssertEqual(PairFlow.summary(paired: false, server: "https://jarvis.example.com"), "Not paired")
        XCTAssertEqual(PairFlow.summary(paired: nil, server: ""), "Jarvis isn't running on this Mac")
    }

    // MARK: the QR itself (CoreImage)

    func testQRImageReadsBackAsThePayload() throws {
        let image = try XCTUnwrap(PairQR.image(for: payload1, side: 240))
        XCTAssertGreaterThanOrEqual(image.width, 240)
        XCTAssertEqual(image.width, image.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        // A white quiet zone around it, as the window's card gives it.
        let code = CIImage(cgImage: image)
        let padded = code.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: image.width + 80, height: image.height + 80)))
        let found = detector.features(in: padded).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [payload1])
    }

    func testQRImageForNothingIsNil() {
        XCTAssertNil(PairQR.image(for: "", side: 240))
    }
}

/// An in-memory link: records requests, answers through `reply` (at once, or on `release()`).
@MainActor
final class FakePairLink: PairLink {
    private(set) var sent: [[String: Any]] = []
    var reply: ([String: Any]) -> [String: Any] = { _ in ["ok": true] }
    var hold = false
    private var held: [() -> Void] = []

    func request(_ body: [String: Any], reply cb: (@MainActor ([String: Any]) -> Void)?) {
        sent.append(body)
        let answer = reply(body)
        if hold { held.append { cb?(answer) } } else { cb?(answer) }
    }

    func release() {
        hold = false
        let pending = held
        held = []
        pending.forEach { $0() }
    }

    func sent(ofType type: String) -> [[String: Any]] { sent.filter { $0["type"] as? String == type } }
}
