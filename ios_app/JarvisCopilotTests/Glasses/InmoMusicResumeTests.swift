import XCTest
@testable import JarvisCopilot

final class InmoMusicResumeTests: XCTestCase {
    func testExistingGoWireBytesAreUnchanged() {
        XCTAssertEqual(InmoCommand.goKey(pressed: true, atMillis: 1000),
                       Data([0x08, 0x01, 0x10, 0x02, 0x2a, 0x0d, 0x08, 0x14, 0x6a, 0x09, 0x08, 0x01, 0x10, 0x04, 0x18, 0x01, 0x20, 0xe8, 0x07]))
    }

    @MainActor
    func testCancelledHoldReleasesKeyWithoutTappingMedia() async throws {
        var packets: [Data] = []
        var sleeps = 0
        do {
            _ = try await InmoMusicResume().run(dismissChat: {}, send: { packets.append($0) },
                sleep: { _ in
                    sleeps += 1
                    if sleeps == 2 { throw CancellationError() }
                })
            XCTFail("cancelled hold must stop the sequence")
        } catch is CancellationError {} catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(packets.count, 2)
        guard packets.count == 2 else { return }
        let control = try XCTUnwrap(InmoWireCodec.decode(packets[1]).firstField(5)).nested()
        let key = try XCTUnwrap(control.firstField(13)).nested()
        XCTAssertEqual(key.firstField(2)?.varint, 4)
        XCTAssertEqual(key.firstField(3)?.varint ?? 0, 0)
    }

    @MainActor
    func testDismissThenDoubleGoThenSideTap() async throws {
        let sequence = InmoMusicResume()
        var events: [String] = []
        var packets: [Data] = []
        var time = Date(timeIntervalSince1970: 1)
        let tapped = try await sequence.run(dismissChat: { events.append("dismiss") }, send: {
            events.append("send"); packets.append($0)
        }, sleep: { time.addTimeInterval($0) }, now: { time })
        XCTAssertTrue(tapped)
        XCTAssertEqual(events, ["dismiss"] + Array(repeating: "send", count: 6))
        guard packets.count == 6 else { return }
        let keys = try packets.map { packet -> [InmoWireField] in
            let control = try XCTUnwrap(InmoWireCodec.decode(packet).firstField(5)).nested()
            XCTAssertEqual(control.firstField(1)?.varint, 20)
            return try XCTUnwrap(control.firstField(13)).nested()
        }
        XCTAssertEqual(keys.map { $0.firstField(2)?.varint ?? 0 }, [4, 4, 4, 4, 0, 0])
        XCTAssertEqual(keys.map { $0.firstField(3)?.varint ?? 0 }, [1, 0, 1, 0, 1, 0])
        XCTAssertEqual(keys.map { $0.firstField(1)?.varint ?? 0 }, [1, 1, 1, 1, 0, 0])
        let times = keys.map { $0.firstField(4)?.varint ?? 0 }
        XCTAssertEqual(times[1] - times[0], 30)
        XCTAssertEqual(times[2] - times[0], 180)
        XCTAssertEqual(times[3] - times[0], 210)
        XCTAssertGreaterThanOrEqual(times[4] - times[3], 400)
        XCTAssertEqual(times[5] - times[4], 30)
    }

    @MainActor
    func testFinalTapIsNotSuppressedByPhoneAudioHeuristic() async throws {
        var packets: [Data] = []
        let tapped = try await InmoMusicResume().run(dismissChat: {}, send: { packets.append($0) },
            sleep: { _ in })
        XCTAssertTrue(tapped)
        XCTAssertEqual(packets.count, 6)
    }

    @MainActor
    func testDismissFailureSendsNoGesturesAndAllowsRetry() async throws {
        let sequence = InmoMusicResume()
        var packets: [Data] = []
        do {
            _ = try await sequence.run(dismissChat: { throw InmoProtocolError.cancelled },
                send: { packets.append($0) }, sleep: { _ in })
            XCTFail("dismissal failure must propagate")
        } catch {}
        XCTAssertTrue(packets.isEmpty)
        _ = try await sequence.run(dismissChat: {}, send: { packets.append($0) }, sleep: { _ in })
        XCTAssertEqual(packets.count, 6)
    }

    @MainActor
    func testGoWriteFailureNeverReachesMediaToggle() async throws {
        var attempts = 0
        do {
            _ = try await InmoMusicResume().run(dismissChat: {}, send: { _ in
                attempts += 1
                throw InmoProtocolError.unavailable("disconnected")
            }, sleep: { _ in })
            XCTFail("write failure must propagate")
        } catch {}
        XCTAssertLessThanOrEqual(attempts, 2, "at most one best-effort key release after failure")
        XCTAssertGreaterThan(attempts, 0)
    }

    @MainActor
    func testConcurrentInvocationIsRejected() async throws {
        let sequence = InmoMusicResume()
        var rejected = false
        _ = try await sequence.run(dismissChat: {
            do {
                _ = try await sequence.run(dismissChat: {}, send: { _ in }, sleep: { _ in })
            } catch { rejected = true }
        }, send: { _ in }, sleep: { _ in })
        XCTAssertTrue(rejected)
    }
}
