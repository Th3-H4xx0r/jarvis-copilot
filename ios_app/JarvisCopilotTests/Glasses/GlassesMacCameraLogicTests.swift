import CoreVideo
import UIKit
import XCTest
@testable import JarvisCopilot

/// "Send to Mac camera": the phone sends the glasses' video only while he has it on, the glasses
/// are live and a Mac asks; it follows the Mac's newest request, backs off after a failure, and
/// draws each live JPEG into the 720×1280 stream.
final class GlassesMacCameraLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testOffUntilHeTurnsItOn() {
        var m = GlassesMacCameraMachine()
        m.glassesLive = true
        m.request = "scr_1"
        XCTAssertEqual(m.phase, .off)
        XCTAssertEqual(m.decide(now: t0), .none)
    }

    func testItWaitsForTheGlassesThenForAMac() {
        var m = GlassesMacCameraMachine()
        m.enabled = true
        XCTAssertEqual(m.phase, .waitingForGlasses)
        m.request = "scr_1"
        XCTAssertEqual(m.decide(now: t0), .none, "no video before the glasses are live")
        m.request = nil
        m.glassesLive = true
        XCTAssertEqual(m.phase, .waitingForMac)
        XCTAssertEqual(m.decide(now: t0), .none)
    }

    func testAMacRequestConnectsOnceAndTheConnectionSends() {
        var m = live()
        m.request = "scr_1"
        XCTAssertEqual(m.decide(now: t0), .connect("scr_1"))
        XCTAssertEqual(m.phase, .connecting)
        XCTAssertEqual(m.decide(now: t0), .none, "one connection per request")
        m.connected()
        XCTAssertEqual(m.phase, .sending)
    }

    func testTheGlassesStoppingOrTheSwitchGoingOffDisconnects() {
        var m = sending()
        m.glassesLive = false
        XCTAssertEqual(m.decide(now: t0), .disconnect)
        XCTAssertEqual(m.phase, .waitingForGlasses)
        m = sending()
        m.enabled = false
        XCTAssertEqual(m.decide(now: t0), .disconnect)
        XCTAssertEqual(m.phase, .off)
        XCTAssertEqual(m.decide(now: t0), .none)
    }

    func testANewerRequestReplacesTheOldConnection() {
        var m = sending()
        m.request = "scr_2"
        XCTAssertEqual(m.decide(now: t0), .disconnect)
        XCTAssertEqual(m.decide(now: t0), .connect("scr_2"))
    }

    func testAFailureWaitsBeforeTryingAgain() {
        var m = sending()
        m.failed("Lost the connection to your Mac.", now: t0)
        XCTAssertEqual(m.phase, .failed("Lost the connection to your Mac."))
        XCTAssertEqual(m.decide(now: t0.addingTimeInterval(1)), .none)
        XCTAssertEqual(m.decide(now: t0.addingTimeInterval(GlassesMacCameraMachine.retryDelay + 0.1)), .connect("scr_1"))
        XCTAssertEqual(m.phase, .connecting)
    }

    func testTheMacEndingItsRequestWaitsForANewOne() {
        var m = sending()
        m.ended()
        XCTAssertEqual(m.phase, .waitingForMac)
        XCTAssertEqual(m.decide(now: t0), .none)
        m.request = "scr_3"
        XCTAssertEqual(m.decide(now: t0), .connect("scr_3"))
    }

    func testTheNewestOpenGlassesRequestIsPicked() {
        let shares: [[String: Any]] = [
            ["id": "scr_old", "reason": "glasses", "status": "live", "created_at": "2026-11-22T10:00:00+00:00"],
            ["id": "scr_new", "reason": "glasses", "status": "requested", "created_at": "2026-11-22T11:00:00+00:00"],
            ["id": "scr_task", "reason": "task", "status": "live", "created_at": "2026-11-22T12:00:00+00:00"],
            ["id": "scr_gone", "reason": "glasses", "status": "ended", "created_at": "2026-11-22T13:00:00+00:00"],
        ]
        XCTAssertEqual(GlassesMacCameraMachine.newestRequest(in: shares), "scr_new")
        XCTAssertNil(GlassesMacCameraMachine.newestRequest(in: [["id": "scr_a", "reason": "anytime", "status": "live"]]))
    }

    func testThePhaseWordsSayWhatToDo() {
        XCTAssertTrue(GlassesMacCameraMachine.Phase.waitingForMac.text.contains("Jarvis Glasses"))
        XCTAssertTrue(GlassesMacCameraMachine.Phase.failed("Lost it.").text.hasPrefix("Lost it."))
    }

    func testFramesFitThe720x1280StreamCentredAndEven() {
        XCTAssertEqual(GlassesMacCameraMachine.fit(CGSize(width: 360, height: 640), in: CGSize(width: 720, height: 1280)),
                       CGRect(x: 0, y: 0, width: 720, height: 1280))
        XCTAssertEqual(GlassesMacCameraMachine.fit(CGSize(width: 1280, height: 720), in: CGSize(width: 720, height: 1280)),
                       CGRect(x: 0, y: 438, width: 720, height: 404))
    }

    func testALiveJpegBecomesA720x1280PixelBuffer() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }.jpegData(compressionQuality: 0.9))
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: 1280,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        let pixels = try XCTUnwrap(GlassesFramePump.render(jpeg: jpeg, pool: pool))
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 720)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 1280)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let p = base + 640 * CVPixelBufferGetBytesPerRow(pixels) + 360 * 4
        XCTAssertGreaterThan(p[2], 200)   // R (BGRA)
        XCTAssertLessThan(p[1], 50)
        XCTAssertLessThan(p[0], 50)
    }

    private func live() -> GlassesMacCameraMachine {
        var m = GlassesMacCameraMachine()
        m.enabled = true
        m.glassesLive = true
        return m
    }

    private func sending() -> GlassesMacCameraMachine {
        var m = live()
        m.request = "scr_1"
        _ = m.decide(now: t0)
        m.connected()
        return m
    }

    // MARK: Raw frames (only WebRTC compresses them)

    private func pixels() -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA, nil, &out)
        return out!
    }

    func testRawFramesGoToTheConnectedMacAndMarkThemselvesRecent() {
        let feed = GlassesRawFeed()
        XCTAssertFalse(feed.recent)
        var sent = 0
        feed.setTarget { _ in sent += 1 }
        feed.push(pixels())
        feed.push(pixels())
        XCTAssertEqual(sent, 2)
        XCTAssertTrue(feed.recent, "raw frames flowing: the JPEG path stands aside")
    }

    func testRawFramesWithNoMacConnectedGoNowhereButStillCount() {
        let feed = GlassesRawFeed()
        var sent = 0
        feed.setTarget { _ in sent += 1 }
        feed.setTarget(nil)
        feed.push(pixels())
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(feed.recent)
    }

    func testTheLivePixelTapReachesItsHandlerAndCanBeCleared() {
        var got = 0
        MetaLivePixels.setHandler { _ in got += 1 }
        MetaLivePixels.deliver(pixels())
        MetaLivePixels.setHandler(nil)
        MetaLivePixels.deliver(pixels())
        XCTAssertEqual(got, 1)
    }
}
