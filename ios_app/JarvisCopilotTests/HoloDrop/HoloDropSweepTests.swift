import XCTest
@testable import JarvisCopilot

/// Bug-sweep regressions for Holo Drop on the iPhone (2026-11-14).
final class HoloDropSweepTests: XCTestCase {

    func testScreenMapWindowsAreFractionsOfTheMap() {
        let w = HoloScreen.Window(rect: CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), app: "Safari")
        XCTAssertEqual(HoloScreenMapView.frame(of: w, in: CGSize(width: 200, height: 100)),
                       CGRect(x: 100, y: 25, width: 100, height: 50))
    }

    func testTiltIsRelativeToHowHeHeldThePhone() {
        XCTAssertEqual(HoloTilt.offset(roll: 0.1, pitch: 0.8, refRoll: 0.1, refPitch: 0.8), .zero)
        XCTAssertGreaterThan(HoloTilt.offset(roll: 0.3, pitch: 0.8, refRoll: 0.1, refPitch: 0.8).width, 0)
        XCTAssertLessThanOrEqual(abs(HoloTilt.offset(roll: 3, pitch: 0, refRoll: 0, refPitch: 0).width), 0.4)
    }

    func testDistanceOnlyReadingIsNotRemembered() {
        XCTAssertFalse(HoloSensing.remembers(HoloLiveReading(deg: nil, confidence: 0.15, distance: 2, source: "ultrasonic")))
        XCTAssertTrue(HoloSensing.remembers(HoloLiveReading(deg: 40, confidence: 0.9, distance: nil, source: "look")))
    }

    func testUploadQueryKeepsPlusSigns() {
        let q = HoloDropClient.query([("name", "a+b & c.jpg"), ("kind", "image")])
        XCTAssertTrue(q.contains("name=a%2Bb%20%26%20c.jpg"), q)
        XCTAssertTrue(q.contains("kind=image"))
    }

    func testOldTempDropsAreSweptRecentOnesKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holo-sweep-\(UUID())")
        let old = root.appendingPathComponent("old"), fresh = root.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86400)], ofItemAtPath: old.path)
        HoloTemp.sweep(root, olderThan: 86400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: direct path: a dead LAN address falls back fast; a receiver's "no" isn't re-sent

    final class Stub: URLProtocol {
        nonisolated(unsafe) static var log: [String] = []
        nonisolated(unsafe) static var lanOK = false
        nonisolated(unsafe) static var lanReply = #"{"ok":true,"outcome":"saved"}"#
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let u = request.url!
            Stub.log.append("\(request.httpMethod ?? "GET") \(u.host ?? "")\(u.path)")
            if u.host == "10.9.9.9" {
                guard Stub.lanOK else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
                let body = request.httpMethod == "GET" ? Data() : Data(Stub.lanReply.utf8)
                reply(request.httpMethod == "GET" ? 405 : 200, body)
                return
            }
            reply(200, Data(#"{"drop":{"id":"d1","state":"delivered"}}"#.utf8))
        }
        private func reply(_ status: Int, _ body: Data) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> HoloDropClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        var c = HoloDropClient(baseURL: URL(string: "https://jarvis.example")!, headers: [:], session: URLSession(configuration: cfg))
        c.directSession = URLSession(configuration: cfg)
        return c
    }

    private var mac: HoloDevice {
        HoloDevice(json: ["id": "m", "kind": "mac", "name": "MacBook",
                          "lan": ["url": "http://10.9.9.9:5000", "token": "t"]])!
    }

    func testUnreachableLanFallsBackToJarvisWithoutPosting() async throws {
        Stub.log = []; Stub.lanOK = false
        let reply = try await client().send(.text("hi"), to: mac, action: .copy, position: nil)
        XCTAssertEqual((reply["drop"] as? [String: Any])?["state"] as? String, "delivered")
        XCTAssertEqual(Stub.log.filter { $0.hasPrefix("POST 10.9.9.9") }.count, 0, "\(Stub.log)")
        XCTAssertTrue(Stub.log.contains("POST jarvis.example/api/holo-drop/drops"), "\(Stub.log)")
    }

    func testReceiverSayingNoIsNotResentThroughJarvis() async {
        Stub.log = []; Stub.lanOK = true; Stub.lanReply = #"{"ok":false,"outcome":"failed"}"#
        do {
            _ = try await client().send(.text("hi"), to: mac, action: .copy, position: nil)
            XCTFail("a receiver's refusal must surface")
        } catch {}
        XCTAssertFalse(Stub.log.contains("POST jarvis.example/api/holo-drop/drops"), "\(Stub.log)")
        Stub.lanReply = #"{"ok":true,"outcome":"saved"}"#
    }
}
