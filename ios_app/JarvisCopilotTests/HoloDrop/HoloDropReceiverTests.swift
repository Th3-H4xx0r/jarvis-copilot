import XCTest
@testable import JarvisCopilot

/// Holo Drop on the iPhone: arrivals, files, the direct receiver, and direction finding.
final class HoloDropReceiverTests: XCTestCase {

    // MARK: arrivals

    func testRecordParsesTheServersDrop() {
        let r = HoloDropRecord(json: ["id": "d1", "kind": "link", "from": "mac-1", "from_name": "MacBook",
                                      "url": "https://apple.com/x", "action": "save_open", "size": 0])
        XCTAssertEqual(r?.action, .saveOpen)
        XCTAssertEqual(r?.sender, "MacBook")
        XCTAssertEqual(r?.webURL?.host, "apple.com")
        XCTAssertNil(HoloDropRecord(json: ["id": "d2", "kind": "nonsense"]))
        XCTAssertNil(HoloDropRecord(json: ["kind": "text"]))
    }

    func testOnlyWebLinksOpen() {
        for bad in ["tel:123", "file:///etc/passwd", "shortcuts://run-shortcut?name=x", "javascript:alert(1)"] {
            XCTAssertNil(HoloDropRecord(json: ["id": "x", "kind": "link", "url": bad])!.webURL, bad)
        }
    }

    func testActionsMapToStepsAndOutcomes() {
        XCTAssertEqual(HoloArrival.plan(.save, kind: "image"), .init(save: true, outcome: "saved"))
        XCTAssertEqual(HoloArrival.plan(.saveCopy, kind: "text"), .init(save: true, copy: true, outcome: "saved_copied"))
        XCTAssertEqual(HoloArrival.plan(.saveOpen, kind: "file"), .init(save: true, open: true, outcome: "saved_opened"))
        XCTAssertEqual(HoloArrival.words("saved_copied"), "Saved + copied")
    }

    func testFileNamesCantEscapeOrHide() {
        XCTAssertEqual(HoloArrival.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(HoloArrival.safeName(".secret"), "secret")
        XCTAssertEqual(HoloArrival.safeName(""), "Holo Drop")
        let long = String(repeating: "a", count: 300) + ".pdf"
        XCTAssertLessThanOrEqual(HoloArrival.safeName(long).count, 120)
        XCTAssertTrue(HoloArrival.safeName(long).hasSuffix(".pdf"))
    }

    func testSameNameTwiceNeverOverwrites() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/IMG.HEIC", "/tmp/x/IMG 2.HEIC"]
        let url = HoloArrival.uniqueURL(in: dir, name: "IMG.HEIC") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "IMG 3.HEIC")
    }

    @MainActor
    func testSavedListDedupesAndCaps() {
        let defaults = UserDefaults(suiteName: "holo-test-\(UUID())")!
        let list = HoloSavedList(defaults: defaults, key: "k")
        let rec = HoloDropRecord(json: ["id": "a", "kind": "text", "text": "hi"])!
        list.add(rec)
        list.add(rec)
        XCTAssertEqual(list.items.count, 1)
        for i in 0..<(HoloSavedList.cap + 5) { list.add(HoloDropRecord(json: ["id": "n\(i)", "kind": "text", "text": "t"])!) }
        XCTAssertEqual(list.items.count, HoloSavedList.cap)
        XCTAssertEqual(HoloSavedList(defaults: defaults, key: "k").items.count, HoloSavedList.cap)   // kept across launches
    }

    // MARK: the direct receiver

    func testHTTPHeadWaitsForTheBlankLineThenParses() {
        let meta = try! JSONSerialization.data(withJSONObject: ["kind": "text", "text": "hi"]).base64EncodedString()
        let raw = "POST /holo-drop HTTP/1.1\r\nX-Holo-Token: abc\r\nContent-Length: 5\r\nX-Holo-Meta: \(meta)\r\n\r\nhello"
        XCTAssertNil(HoloHTTPHead.parse(Data("POST /holo-drop HTTP/1.1\r\nX-Holo".utf8)))
        let head = HoloHTTPHead.parse(Data(raw.utf8))!
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.headers["x-holo-token"], "abc")
        XCTAssertEqual(head.contentLength, 5)
        XCTAssertEqual(head.meta()?["text"] as? String, "hi")
        XCTAssertEqual(String(data: Data(raw.utf8).dropFirst(head.length), encoding: .utf8), "hello")
    }

    func testTokenCompare() {
        XCTAssertTrue(HoloLanReceiver.same("abc", "abc"))
        XCTAssertFalse(HoloLanReceiver.same("abc", "abd"))
        XCTAssertFalse(HoloLanReceiver.same("abc", "abcd"))
        XCTAssertEqual(HoloLanReceiver.randomToken().count, 48)
    }

    // MARK: hearing the Mac

    /// The Mac's chirp, built exactly as `HoloBeacons.chirpSamples` does.
    private func chirp(_ nonce: String, rate: Double, amplitude: Float) -> [Float] {
        let per = Int(rate * HoloBeaconCode.chirpSymbol)
        var out: [Float] = []
        var phase = 0.0
        for bit in HoloBeaconCode.chirpBits(nonce) {
            let step = 2 * Double.pi * (bit ? HoloBeaconCode.oneHz : HoloBeaconCode.zeroHz) / rate
            for _ in 0..<per { out.append(amplitude * Float(sin(phase))); phase += step }
        }
        return out
    }

    func testFindsTheChirpInNoise() {
        let rate = 48_000.0
        var x = (0..<Int(rate * 1.2)).map { _ in Float.random(in: -0.01...0.01) }
        let c = chirp("4242", rate: rate, amplitude: 0.02)
        let at = 17_000
        for (i, v) in c.enumerated() { x[at + i] += v }
        let hit = HoloChirpDecoder.find(x, rate: rate, nonce: "4242")
        XCTAssertNotNil(hit)
        XCTAssertEqual(Double(hit?.start ?? 0), Double(at), accuracy: rate * 0.004)
        XCTAssertGreaterThan(hit?.score ?? 0, 0.7)
        XCTAssertNil(HoloChirpDecoder.find(x, rate: rate, nonce: "999"), "another phone's chirp isn't ours")
    }

    func testSilenceIsNotAChirp() {
        let x = (0..<48_000).map { _ in Float.random(in: -0.01...0.01) }
        XCTAssertNil(HoloChirpDecoder.find(x, rate: 48_000, nonce: "4242"))
    }

    func testStereoLevelsGiveLeftOrRight() {
        XCTAssertLessThan(HoloChirpDecoder.side(left: 4, right: 1)!, 0)
        XCTAssertGreaterThan(HoloChirpDecoder.side(left: 1, right: 4)!, 0)
        XCTAssertEqual(HoloChirpDecoder.side(left: 1, right: 1.1), 0)
    }

    // MARK: seeing the Mac

    func testFindsTheFlashingScreenInTheCameraGrid() {
        let cols = 12, rows = 16, code = HoloBeaconCode.flashFrames("777")
        var frames: [[Float]] = [], times: [Double] = []
        let start = 0.43
        for f in 0..<90 {                                   // 3 s at 30 fps
            let t = Double(f) / 30
            var grid = (0..<(cols * rows)).map { _ in Float(100 + Float.random(in: -2...2)) }
            let slot = Int(((t - start) * HoloBeaconCode.flashHz).rounded(.down))
            if t >= start, slot < code.count, code[slot] {
                for r in 6...8 { for c in 8...9 { grid[r * cols + c] += 9 } }   // the Mac, right of centre
            }
            frames.append(grid)
            times.append(t)
        }
        let hit = HoloFlashDetector.detect(frames: frames, times: times, cols: cols, code: code)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.x ?? 0, 0.75, accuracy: 0.06)
        XCTAssertGreaterThan(HoloFlashDetector.offset(x: hit?.x ?? 0, fovDeg: 50), 5)
    }

    func testNoFlashNoHit() {
        let frames = (0..<90).map { _ in (0..<192).map { _ in Float(100 + Float.random(in: -2...2)) } }
        let times = (0..<90).map { Double($0) / 30 }
        XCTAssertNil(HoloFlashDetector.detect(frames: frames, times: times, cols: 12, code: HoloBeaconCode.flashFrames("777")))
    }

    func testPortraitFieldOfViewIsNarrower() {
        XCTAssertLessThan(HoloFlashDetector.portraitFOV(landscapeFOV: 70, width: 4032, height: 3024), 70)
        XCTAssertEqual(HoloFlashDetector.offset(x: 0.5, fovDeg: 50), 0, accuracy: 1e-9)
    }

    // MARK: matching the Mac and the server

    func testBeaconCodesMatchTheMac() {
        XCTAssertEqual(HoloBeaconCode.code16("4242"), 4242)
        XCTAssertEqual(HoloBeaconCode.chirpBits("1").count, 20)
        XCTAssertEqual(HoloBeaconCode.flashFrames("1").count, 15)
        XCTAssertEqual(Array(HoloBeaconCode.chirpBits("1").prefix(4)), [true, false, true, false])
    }

    func testBluetoothTagIsFNVOfTheDeviceID() {
        XCTAssertEqual(HoloBLE.tag("mac-1"), "HD93d11faa")    // same formula as the Mac's HoloBLEAdvertiser
    }

    func testAWalkForgetsRememberedBearings() {
        XCTAssertFalse(HoloMovement.moved(steps: 5))
        XCTAssertTrue(HoloMovement.moved(steps: 40))
    }

    func testLiveReadingOverridesWeakerRememberedBearing() {
        let d = HoloDevice(json: ["id": "m", "kind": "mac", "bearing": ["deg": 10, "confidence": 0.3]])!
        let strong = d.applying(HoloLiveReading(deg: 80, confidence: 0.9, distance: 2, source: "look"), nearest: true)
        XCTAssertEqual(strong.bearingDeg, 80)
        XCTAssertEqual(strong.distance, 2)
        XCTAssertTrue(strong.nearest)
        let weak = d.applying(HoloLiveReading(deg: 200, confidence: 0.1, distance: nil, source: "ultrasonic"), nearest: false)
        XCTAssertEqual(weak.bearingDeg, 10)
    }

    func testUWBAzimuthIsRightPositive() {
        XCTAssertEqual(HoloNearby.azimuthDeg(SIMD3<Float>(0.5, 0, -0.866)), 30, accuracy: 0.1)
        XCTAssertEqual(HoloNearby.azimuthDeg(SIMD3<Float>(0, 0, -1)), 0, accuracy: 1e-6)
    }

    @MainActor
    func testPopupSaysWhatHappened() {
        let mac = HoloDevice(json: ["id": "m", "kind": "mac", "name": "MacBook"])!
        XCTAssertEqual(HoloOrbitModel.result(["state": "landed", "outcome": "opened"], device: mac), .landed("Landed on MacBook · Opened"))
        XCTAssertEqual(HoloOrbitModel.result(["state": "held"], device: mac), .sent("Sent — waiting for MacBook"))
        if case .failed = HoloOrbitModel.result(["state": "failed", "error": "x"], device: mac) {} else { XCTFail("failed drop") }
    }

    func testDropWaitingLinkOpensTheDrop() {
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://holo-drop?drop=abc")!), .holoDrop(drop: "abc"))
        XCTAssertEqual(HoloDropActivityText.url("abc")?.absoluteString, "jarviscopilot://holo-drop?drop=abc")
        XCTAssertEqual(HoloDropActivityText.headline(.init(title: "x", from: "Mac", kind: "link", count: 3)), "3 drops waiting")
    }

    func testArrivalDefaultsMergePerDevice() {
        XCTAssertEqual(HoloDefaults.action(json: "", device: "p1", fallback: .save), .save)
        let one = HoloDefaults.merge(json: #"{"mac-1":"open"}"#, device: "p1", action: .copy)
        XCTAssertEqual(HoloDefaults.action(json: one, device: "p1", fallback: .save), .copy)
        XCTAssertEqual(HoloDefaults.action(json: one, device: "mac-1", fallback: .save), .open)
        XCTAssertEqual(HoloDefaults.action(json: "not json", device: "p1", fallback: .saveOpen), .saveOpen)
        XCTAssertEqual(HoloDefaults.action(json: HoloDefaults.merge(json: "garbage", device: "p1", action: .open),
                                           device: "p1", fallback: .save), .open)
    }
}
