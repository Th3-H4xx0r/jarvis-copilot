import XCTest
@testable import JarvisCopilot

/// The real HTTP path against `dashcam_fake.py` running on the Mac (the simulator shares its
/// loopback). Skipped unless the fakes are up:
///   python3 skills/smart-home/jarvis-dashcam/scripts/dashcam_fake.py make-sample /tmp/fc && \
///   python3 …/dashcam_fake.py serve /tmp/fc --port 8099 &
///   cp -R /tmp/fc /tmp/fcpb && python3 …/dashcam_fake.py serve /tmp/fcpb --port 8098 --playback-required &
@MainActor
final class DashcamLiveCameraTests: XCTestCase {
    private func requireFake(_ port: Int) async throws -> URL {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        guard await DashcamDetect.probe(host: "127.0.0.1:\(port)", timeout: 1) != nil else {
            throw XCTSkip("fake camera not running on :\(port)")
        }
        return base
    }

    private func makeSync(base: URL, root: URL, server: FakeSyncServer, parked: Bool) -> DashcamSync {
        let sync = DashcamSync()
        var setup = DashcamSetup(ssid: "FAKE", family: .viidure, cameraID: "FAKE-A4-0001", host: "\(base.host!):\(base.port!)")
        sync.setupProvider = { setup }
        sync.cameraFactory = { s in DashcamDetect.camera(family: .viidure, base: URL(string: "http://" + s.host!)!) }
        sync.server = server
        sync.fetcher = DashcamDownloader(session: URLSession(configuration: .ephemeral),
                                         resumeDir: root.appendingPathComponent("resume"))
        sync.uploader = DashcamUploader(file: root.appendingPathComponent("uploads.json"))
        sync.storage = DashcamStorage(root: root)
        sync.parked = { parked }
        sync.onCameraProvider = { true }
        sync.tzOffset = { -5 * 3600 }
        _ = setup
        setup.listingNeedsPlayback = false
        return sync
    }

    func testAFullPassOverRealHTTP() async throws {
        let base = try await requireFake(8099)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeSyncServer()
        let sync = makeSync(base: base, root: root, server: server, parked: false)
        let report = await sync.syncPass()
        XCTAssertGreaterThanOrEqual(report.listed, 10, "4 front + 4 rear + event + parking + photo")
        XCTAssertGreaterThanOrEqual(report.gps, 6, "GPS read off the tails for every finished clip")
        let anyFixes = server.fixes.values.max() ?? 0
        XCTAssertEqual(anyFixes, 30, "30 one-second fixes per sample clip")
        XCTAssertGreaterThan(report.thumbs, 0)
        XCTAssertEqual(Set(report.downloaded.map { ($0 as NSString).lastPathComponent.hasSuffix(".jpg") }), [true, false],
                       "the event clip and the photo came down")
        for path in report.downloaded {
            let file = sync.cameraFiles.first { $0.path == path }!
            XCTAssertTrue(sync.storage.exists(camera: "FAKE-A4-0001", file: file), "\(path) is on the phone in full")
        }
        XCTAssertEqual(sync.recording, true)
        let queued = await sync.uploader.jobs
        for job in queued {
            let real = (try FileManager.default.attributesOfItem(atPath: job.localPath)[.size] as? NSNumber)?.int64Value
            XCTAssertEqual(job.size, real, "uploads announce the real size, not the KB-rounded listing")
        }
        let again = await sync.syncPass()
        XCTAssertTrue(Set(again.downloaded).isDisjoint(with: report.downloaded), "nothing is downloaded twice")
        XCTAssertEqual(again.downloaded.map { ($0 as NSString).deletingLastPathComponent }, ["/mnt/card/park"],
                       "the parking clip (newest in its folder) comes once its size has held still")
        let third = await sync.syncPass()
        XCTAssertTrue(third.downloaded.isEmpty)
    }

    func testPlaybackOnlyCameraIsLeftRecordingWhileDrivingAndRestoredWhenParked() async throws {
        let base = try await requireFake(8098)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-pb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driving = makeSync(base: base, root: root, server: FakeSyncServer(), parked: false)
        _ = await driving.syncPass()
        XCTAssertEqual(driving.phase, .waitingForPark)
        let cam = DashcamDetect.camera(family: .viidure, base: base)!
        let stillRecording = try await cam.isRecording()
        XCTAssertTrue(stillRecording, "never paused while driving")

        let parkedSync = makeSync(base: base, root: root, server: FakeSyncServer(), parked: true)
        let report = await parkedSync.syncPass()
        XCTAssertTrue(report.usedPlayback)
        XCTAssertGreaterThan(report.listed, 0)
        let after = try await cam.isRecording()
        XCTAssertTrue(after, "recording restored after playback mode")
    }
}
