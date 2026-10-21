import Foundation
import XCTest
@testable import JarvisCopilot

/// Oct 21: a socket accepted and closed within ~100 ms, 276 times in 12 minutes. A hello only
/// counts as recovery once the socket stays up.
final class BridgeReconnectTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFlappingSocketKeepsBackingOffAndStaysInOutage() {
        var r = BridgeReconnect()
        var now = t0
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            r.hello(at: now)
            now += 0.1                                // closed right after its hello
            let wait = r.drop(at: now)
            waits.append(wait)
            now += wait
        }
        XCTAssertEqual(waits, [2, 4, 8, 16, 32, 64, 64, 64], "the old code waited 2 s every time")
        XCTAssertEqual(r.outageStartedAt, t0 + 0.1, "the first drop started it; the flaps never ended it")
        XCTAssertTrue(r.inOutage(at: t0 + 301, grace: 300), "five minutes on, the keepalive can let go")
    }

    func testASocketThatStayedUpIsARealRecovery() {
        var r = BridgeReconnect()
        _ = r.drop(at: t0)
        _ = r.drop(at: t0 + 2)
        XCTAssertEqual(r.attempt, 2)
        r.hello(at: t0 + 10)
        XCTAssertNil(r.outageStartedAt, "online for now")
        XCTAssertFalse(r.inOutage(at: t0 + 1000, grace: 300))
        XCTAssertEqual(r.drop(at: t0 + 10 + BridgeReconnect.stableAfter), 2, "backoff starts afresh")
        XCTAssertEqual(r.outageStartedAt, t0 + 10 + BridgeReconnect.stableAfter, "a new outage")
    }

    func testFailedTriesWithoutAHelloStillBackOff() {
        var r = BridgeReconnect()
        XCTAssertEqual((0..<3).map { r.drop(at: t0 + Double($0)) }, [2, 4, 8])
        XCTAssertEqual(r.outageStartedAt, t0)
    }

    func testTheDropCauseNamesACloseCodeOrTheError() {
        let tooBig = NSError(domain: NSURLErrorDomain, code: -1005)
        XCTAssertEqual(BridgeReconnect.cause(of: tooBig, closeCode: 1009), "close.1009")
        XCTAssertEqual(BridgeReconnect.cause(of: tooBig, closeCode: 0), "NSURL.-1005")
        XCTAssertEqual(BridgeReconnect.cause(of: NSError(domain: NSPOSIXErrorDomain, code: 57), closeCode: 0),
                       "NSPOSIX.57")
    }
}
