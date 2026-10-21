import CoreLocation
import XCTest
@testable import JarvisCopilot

/// Getting a clip out of the app (Save to Photos, the share sheet): where its bytes come from, what the
/// copy is called, and what Photos is told about it.
final class DashcamExportTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DashcamExportTests-\(UUID().uuidString)")
        DashcamStubProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func clip(_ extra: [String: Any] = [:]) throws -> DashcamServerClip {
        var json: [String: Any] = ["id": "c1", "path": "/mnt/card/video_back/2026_1021_161737_R.ts", "kind": "normal",
                                   "lens": "rear", "start": "2026-10-21T21:17:37Z", "on_camera": false]
        json.merge(extra) { $1 }
        return try XCTUnwrap(DashcamServerClip(json: json))
    }

    func testTheCopyIsNamedForWhenAndWhichCamera() throws {
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        XCTAssertEqual(DashcamExport.fileName(for: try clip(), ext: "mp4", timeZone: chicago),
                       "Dashcam 2026-10-21 16.17.37 Rear.mp4")
        XCTAssertEqual(DashcamExport.fileName(for: try clip(["kind": "event", "lens": "front"]), ext: "mp4", timeZone: chicago),
                       "Dashcam Event 2026-10-21 16.17.37 Front.mp4")
        XCTAssertEqual(DashcamExport.fileName(for: try clip(["kind": "photo", "lens": "front"]), ext: "jpg", timeZone: chicago),
                       "Dashcam 2026-10-21 16.17.37 Front.jpg")
    }

    func testThePhonesOwnCopyComesFirst() throws {
        let local = URL(fileURLWithPath: "/tmp/clip.ts")
        let camera = URL(string: "http://192.168.1.254/clip.mp4")!
        let c = try clip(["destinations": ["d1": ["state": "done", "file_id": "F"]]])
        XCTAssertEqual(DashcamExport.origin(of: c, local: local, camera: camera), .phone(local))
        XCTAssertEqual(DashcamExport.origin(of: c, local: nil, camera: camera), .camera(camera))
    }

    /// Drive: the full-quality file, never the light 720p streaming copy.
    func testFromDriveItIsTheFullQualityFile() throws {
        let c = try clip(["destinations": ["d1": ["state": "done", "file_id": "F", "preview_file_id": "P"]]])
        XCTAssertEqual(DashcamExport.origin(of: c, local: nil, camera: nil), .drive(destinationID: "d1", fileID: "F"))
    }

    func testOtherwiseFromYourUploadsOrNowhere() throws {
        XCTAssertEqual(DashcamExport.origin(of: try clip(["uploaded": true]), local: nil, camera: nil), .server)
        XCTAssertEqual(DashcamExport.origin(of: try clip(), local: nil, camera: nil), .nowhere)
        XCTAssertEqual(DashcamExport.origin(of: try clip(["kind": "photo"]), local: nil, camera: nil), .server,
                       "the server serves a photo's bytes whatever its upload state, as the player asks it")
    }

    /// Staged under its new name without a second copy of the bytes; staging again replaces it.
    func testStagingNamesTheCopy() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("card_video_back_2026_1021_161737_R.mp4")
        try Data("video".utf8).write(to: source)
        let share = dir.appendingPathComponent("share")
        let out = try DashcamExport.stage(source, as: "Dashcam 2026-10-21 16.17.37 Rear.mp4", in: share)
        XCTAssertEqual(out.lastPathComponent, "Dashcam 2026-10-21 16.17.37 Rear.mp4")
        XCTAssertEqual(try Data(contentsOf: out), Data("video".utf8))
        XCTAssertNoThrow(try DashcamExport.stage(source, as: out.lastPathComponent, in: share))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original stays where it was")
    }

    func testADownloadLandsWithItsTypesExtension() async throws {
        let body = Data(repeating: 7, count: 4096)
        DashcamStubProtocol.on("/clips/c1/stream") { _ in .init(status: 200, headers: ["Content-Type": "video/mp2t"], body: body) }
        let out = try await DashcamExport.download(URLRequest(url: URL(string: "https://jarvis.test/clips/c1/stream")!),
                                                   into: dir, session: DashcamStubProtocol.session()) { _ in }
        XCTAssertEqual(out.pathExtension, "ts", "a .ts is remuxed before Photos sees it")
        XCTAssertEqual(try Data(contentsOf: out), body)
    }

    func testAFailedDownloadSaysSo() async throws {
        DashcamStubProtocol.on("/clips/c1/stream") { _ in .init(status: 404) }
        do {
            _ = try await DashcamExport.download(URLRequest(url: URL(string: "https://jarvis.test/clips/c1/stream")!),
                                                 into: dir, session: DashcamStubProtocol.session()) { _ in }
            XCTFail("a 404 isn't a clip")
        } catch let error as DashcamExport.Failure {
            XCTAssertEqual(error, .http(404))
        }
    }

    /// Photos files it at the moment it was recorded and where, not today at home.
    func testPhotosGetsTheClipsTimeAndPlace() throws {
        let c = try clip()
        let fixes = [DashcamFix(t: c.start.timeIntervalSince1970 + 1, lat: 29.73, lon: -95.43, speed: 0, heading: 90),
                     DashcamFix(t: c.start.timeIntervalSince1970 + 2, lat: 29.74, lon: -95.44, speed: 3, heading: 90)]
        let item = DashcamExport.PhotosItem(file: URL(fileURLWithPath: "/tmp/a.mp4"), clip: c, fixes: fixes)
        XCTAssertEqual(item.date, c.start)
        XCTAssertEqual(item.location?.coordinate.latitude ?? 0, 29.73, accuracy: 1e-9)
        XCTAssertEqual(item.location?.coordinate.longitude ?? 0, -95.43, accuracy: 1e-9)
        XCTAssertFalse(item.isPhoto)
        let photo = DashcamExport.PhotosItem(file: URL(fileURLWithPath: "/tmp/a.jpg"), clip: try clip(["kind": "photo"]), fixes: [])
        XCTAssertNil(photo.location)
        XCTAssertTrue(photo.isPhoto)
    }
}
