import XCTest
@testable import JarvisCopilot

// MARK: Fakes

final class FakeDashcam: DashcamCamera, @unchecked Sendable {
    let family = DashcamFamily.viidure
    let http = DashcamHTTP(base: URL(string: "http://192.168.169.1")!)
    var files: [DashcamFile] = []
    var refuseOutsidePlayback = false
    var inPlayback = false
    var recordingOn = true
    var calls: [String] = []
    var gpsByPath: [String: [DashcamFix]] = [:]

    func info() async throws -> DashcamCameraInfo { DashcamCameraInfo(id: "CAM", family: .viidure) }
    func files(tzOffset: Int) async throws -> [DashcamFile] {
        calls.append("files")
        if refuseOutsidePlayback && !inPlayback { throw DashcamError.camera("getfilelist: not in playback mode") }
        return files
    }
    func thumbnailURL(_ file: DashcamFile) -> URL? { nil }
    func thumbnail(_ file: DashcamFile) async -> Data? { Data([0xFF, 0xD8] + Array(repeating: 0, count: 200)) }
    func setTime(_ date: Date, timeZone: TimeZone) async throws { calls.append("time") }
    func isRecording() async throws -> Bool { recordingOn }
    func setRecording(_ on: Bool) async throws { calls.append("rec=\(on)"); recordingOn = on }
    func lock() async throws { calls.append("lock") }
    func snapshot() async throws -> String? { nil }
    func settings() async throws -> [DashcamSettingItem] { [] }
    func set(_ name: String, _ value: String) async throws {}
    func sdInfo() async throws -> DashcamSDInfo { DashcamSDInfo(ok: true) }
    func format() async throws {}
    func delete(_ file: DashcamFile) async throws {}
    func setWiFi(ssid: String?, password: String?) async throws {}
    func playback(_ enter: Bool) async throws {
        calls.append("playback=\(enter)")
        inPlayback = enter
        if enter { recordingOn = false }   // the worst case: playback mode pauses recording
    }
    func gps(_ file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix] { gpsByPath[file.path] ?? [] }
}

final class FakeSyncServer: DashcamSyncServer, @unchecked Sendable {
    var inventoried: [DashcamFile] = []
    var fixes: [String: Int] = [:]
    var thumbs = Set<String>()
    var phone: [String: String] = [:]
    var uploadedIDs = Set<String>()
    var rules = DashcamRules()
    var unreachable = false

    func upsertCamera(_ info: DashcamCameraInfo, ssid: String) async throws {}
    func inventory(cameraID: String, files: [DashcamFile]) async throws -> [String: DashcamInventoryRow] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        inventoried = files
        var out: [String: DashcamInventoryRow] = [:]
        for f in files {
            let id = DashcamIDs.clipID(cameraID: cameraID, path: f.path)
            out[f.path] = DashcamInventoryRow(json: ["id": id, "path": f.path, "has_gps": fixes[id] != nil,
                                                     "has_thumb": thumbs.contains(id), "uploaded": uploadedIDs.contains(id)])
        }
        return out
    }
    func putFixes(clipID: String, fixes f: [DashcamFix]) async throws { fixes[clipID] = f.count }
    func putThumb(clipID: String, jpeg: Data) async throws { thumbs.insert(clipID) }
    func setPhone(clipID: String, state: String, error: String?) async throws { phone[clipID] = state }
    func state() async throws -> DashcamServerState {
        DashcamServerState(rules: rules, destinations: [], counts: [:], stagingBytes: 0, stagingCap: 0)
    }
    func clips(_ filter: DashcamAPI.ClipFilter, cursor: String?, limit: Int) async throws -> (clips: [DashcamServerClip], next: String?) {
        ([], nil)
    }
}

final class FakeFetcher: DashcamFetcher, @unchecked Sendable {
    var fetched: [URL] = []
    var failAfter: Int?
    var onFetch: (() -> Void)?
    func download(_ url: URL, to dest: URL, key: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if let n = failAfter, fetched.count >= n { throw DashcamError.notConnected }
        fetched.append(url)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dest)
        onFetch?()
    }
}

final class FakeUploadServer: DashcamUploadServer, @unchecked Sendable {
    var chunks: [(String, Int, Int)] = []
    var received: Set<Int> = []
    var full = false
    var completed: [String] = []
    var failChunk: Int?
    var start: DashcamAPI.UploadStart?
    func startUpload(clipID: String, size: Int64, sha256: String) async throws -> DashcamAPI.UploadStart {
        if let start { return start }
        if full { return .full(retryAfter: 60) }
        return .ticket(DashcamUploadTicket(uploadID: "u_" + clipID, chunkSize: 4, received: received))
    }
    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool) async throws {
        if index == failChunk { failChunk = nil; throw URLError(.networkConnectionLost) }
        chunks.append((uploadID, index, data.count))
        received.insert(index)
    }
    func completeUpload(_ uploadID: String) async throws { completed.append(uploadID) }
}

// MARK: Sync pass

@MainActor
final class DashcamSyncTests: XCTestCase {
    private var root: URL!
    private var cam: FakeDashcam!
    private var server: FakeSyncServer!
    private var fetcher: FakeFetcher!
    private var sync: DashcamSync!
    private var onCamera = true
    private var parked = false

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-sync-\(UUID().uuidString)")
        cam = FakeDashcam()
        server = FakeSyncServer()
        fetcher = FakeFetcher()
        onCamera = true
        parked = false
        sync = DashcamSync()
        sync.setupProvider = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM") }
        sync.cameraFactory = { [unowned self] _ in self.cam }
        sync.server = server
        sync.fetcher = fetcher
        sync.uploader = DashcamUploader(file: root.appendingPathComponent("uploads.json"))
        sync.storage = DashcamStorage(root: root)
        sync.parked = { [unowned self] in self.parked }
        sync.onCameraProvider = { [unowned self] in self.onCamera }
        sync.tzOffset = { 0 }
        sync.now = { Date(timeIntervalSince1970: 1_790_010_000) }
        cam.files = [
            file(.normal, .front, at: 0), file(.normal, .front, at: 60), file(.normal, .front, at: 120),
            file(.normal, .rear, at: 0), file(.normal, .rear, at: 60),
            file(.event, .front, at: 30, folder: "emr"), file(.photo, .front, at: 40, folder: "event"),
        ]
        for f in cam.files where f.isVideo {
            cam.gpsByPath[f.path] = [DashcamFix(t: f.start.timeIntervalSince1970, lat: 41, lon: -87, speed: 10, heading: 0)]
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ kind: DashcamClipKind, _ lens: DashcamLens, at t: TimeInterval, folder: String = "loop") -> DashcamFile {
        DashcamFile(path: "/mnt/card/\(folder)/\(lens.rawValue)_\(Int(t)).mp4", kind: kind, lens: lens,
                    start: Date(timeIntervalSince1970: 1_790_000_000 + t), durationS: 60, size: 10, folder: folder)
    }

    func testAPassReadsGPSThumbsAndPullsEventsAndPhotosButSkipsClipsStillRecording() async {
        let report = await sync.syncPass()
        XCTAssertEqual(report.listed, 7)
        // Newest front (120) and newest rear (60) are still being written → no GPS yet.
        XCTAssertEqual(report.gps, 4)
        XCTAssertEqual(server.fixes.count, 4)
        XCTAssertEqual(Set(fetcher.fetched.map(\.lastPathComponent)), ["front_30.mp4", "front_40.mp4"],
                       "events + photos always; normal footage is off by default")
        XCTAssertEqual(report.downloaded.count, 2)
        let pending = await sync.uploader.pendingCount
        XCTAssertEqual(pending, 2, "downloads go straight onto the upload queue")
        XCTAssertFalse(cam.calls.contains { $0.hasPrefix("playback") }, "never touches playback mode when listing works")
        XCTAssertTrue(cam.calls.contains("time"), "the camera clock is synced every pass")
    }

    func testTheNewestClipIsTakenOnceItsSizeHoldsStill() async {
        _ = await sync.syncPass()
        let second = await sync.syncPass()       // same sizes → now stable
        XCTAssertEqual(second.gps, 2)
        XCTAssertEqual(server.fixes.count, 6)
    }

    func testNormalFootageFollowsTheRulesAndFetchRangeForcesIt() async {
        var rules = DashcamRules(); rules.normal = .front
        sync.rules = rules
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_0.mp4"))
        XCTAssertFalse(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"))
        // Jarvis asks for the rear clip around t=0..30 explicitly.
        let n = await sync.fetch(from: Date(timeIntervalSince1970: 1_790_000_000), to: Date(timeIntervalSince1970: 1_790_000_010))
        XCTAssertGreaterThanOrEqual(n, 2)
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"))
    }

    func testAPlaybackOnlyCameraWaitsForParkAndNeverStopsRecordingWhileDriving() async {
        cam.refuseOutsidePlayback = true
        parked = false
        var setup = DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM")
        sync.setupProvider = { setup }
        _ = await sync.syncPass()
        XCTAssertEqual(sync.phase, .waitingForPark)
        XCTAssertFalse(cam.calls.contains("playback=true"))
        XCTAssertTrue(cam.recordingOn)
        // Parked: enters playback, lists, exits, and recording is back on.
        parked = true
        setup.listingNeedsPlayback = true
        let report = await sync.syncPass()
        XCTAssertTrue(report.usedPlayback)
        XCTAssertEqual(cam.calls.filter { $0.hasPrefix("playback") }, ["playback=true", "playback=false"])
        XCTAssertTrue(cam.recordingOn, "recording restored after playback mode")
        XCTAssertGreaterThan(report.listed, 0)
    }

    func testLeavingTheCameraWiFiStopsDownloads() async {
        var rules = DashcamRules(); rules.normal = .all
        sync.rules = rules
        fetcher.onFetch = { [unowned self] in self.onCamera = false }
        _ = await sync.syncPass()
        XCTAssertEqual(fetcher.fetched.count, 1, "stops after the Wi‑Fi drops")
    }

    func testServerDownStillDownloadsUsingLocalIDs() async {
        server.unreachable = true
        let report = await sync.syncPass()
        XCTAssertEqual(report.downloaded.count, 2)
        let pending = await sync.uploader.jobs.map(\.clipID)
        XCTAssertEqual(Set(pending), Set(report.downloaded.map { DashcamIDs.clipID(cameraID: "CAM", path: $0) }))
    }

    func testAnEventClipStillBeingWrittenWaitsForAStableSize() async {
        cam.files.append(DashcamFile(path: "/mnt/card/emr/front_9990.mp4", kind: .event, lens: .front,
                                     start: Date(timeIntervalSince1970: 1_790_009_990), durationS: 20, size: 10, folder: "emr"))
        _ = await sync.syncPass()
        XCTAssertFalse(fetcher.fetched.map(\.lastPathComponent).contains("front_9990.mp4"), "started 10 s ago")
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_9990.mp4"), "same size twice → done")
    }

    func testClipIDMatchesTheServerFormula() {
        // sha1("CAM:/mnt/card/loop/a.mp4")[:20], computed with Python's hashlib.
        XCTAssertEqual(DashcamIDs.clipID(cameraID: "CAM", path: "/mnt/card/loop/a.mp4"), "c_fd34c4c010f0bc429c01")
    }
}

// MARK: Uploader

final class DashcamUploaderTests: XCTestCase {
    private func tempFile(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString).mp4")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    func testChunkMath() {
        XCTAssertEqual(DashcamUploader.chunkCount(size: 16, chunk: 4), 4)
        XCTAssertEqual(DashcamUploader.chunkCount(size: 17, chunk: 4), 5)
        XCTAssertEqual(DashcamUploader.chunkCount(size: 0, chunk: 4), 0)
    }

    func testBackoffDoublesToTenMinutes() {
        XCTAssertEqual(DashcamUploader.backoff(attempts: 1), 30)
        XCTAssertEqual(DashcamUploader.backoff(attempts: 2), 60)
        XCTAssertEqual(DashcamUploader.backoff(attempts: 10), 600)
    }

    func testSHA256OfAKnownFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abc-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try DashcamUploader.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testUploadResumesFromWhatTheServerAlreadyHas() async throws {
        let url = try tempFile(10)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "c1", local: url, size: 10, kind: .event)
        let server = FakeUploadServer()
        server.received = [0]                 // chunk 0 arrived before the Wi‑Fi dropped
        let done = await uploader.run(server: server, cellular: false)
        XCTAssertEqual(done, ["c1"])
        XCTAssertEqual(server.chunks.map(\.1), [1, 2], "only the missing chunks")
        XCTAssertEqual(server.chunks.last?.2, 2, "short last chunk")
        XCTAssertEqual(server.completed, ["u_c1"])
        let left = await uploader.pendingCount
        XCTAssertEqual(left, 0)
    }

    func testADroppedChunkBacksOffAndTheNextRunFinishes() async throws {
        let url = try tempFile(12)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "c1", local: url, size: 12, kind: .event)
        let server = FakeUploadServer()
        server.failChunk = 1
        var clock = Date(timeIntervalSince1970: 1000)
        let first = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertTrue(first.isEmpty)
        let job = await uploader.jobs.first
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertEqual(job?.notBefore, clock.addingTimeInterval(30))
        let early = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertTrue(early.isEmpty, "waits out the backoff")
        clock = clock.addingTimeInterval(31)
        let later = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertEqual(later, ["c1"])
        XCTAssertEqual(server.chunks.map(\.1), [0, 1, 2], "chunk 0 was not sent twice")
    }

    func testAlreadyUploadedClipsLeaveTheQueueAndTooLargeOnesPark() async throws {
        let a = try tempFile(4), b = try tempFile(4)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "a", local: a, size: 4, kind: .event)
        let server = FakeUploadServer()
        server.start = .alreadyThere
        let done = await uploader.run(server: server, cellular: false)
        XCTAssertEqual(done, ["a"])
        XCTAssertTrue(server.chunks.isEmpty, "nothing re-sent")
        await uploader.enqueue(clipID: "b", local: b, size: 4, kind: .event)
        server.start = .tooLarge
        let none = await uploader.run(server: server, cellular: false)
        XCTAssertTrue(none.isEmpty)
        let job = await uploader.jobs.first
        XCTAssertNotNil(job?.lastError)
        XCTAssertGreaterThan(job?.notBefore ?? .distantPast, Date().addingTimeInterval(3600))
    }

    func testFullStagingStopsTheRunAndNormalFootageWaitsForWiFi() async throws {
        let ev = try tempFile(4), normal = try tempFile(4)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "n", local: normal, size: 4, kind: .normal)
        await uploader.enqueue(clipID: "e", local: ev, size: 4, kind: .event)
        let server = FakeUploadServer()
        let onCellular = await uploader.run(server: server, cellular: true)
        XCTAssertEqual(onCellular, ["e"], "events go over mobile data, normal footage waits")
        server.full = true
        let blocked = await uploader.run(server: server, cellular: false)
        XCTAssertTrue(blocked.isEmpty)
        let job = await uploader.jobs.first
        XCTAssertEqual(job?.lastError, "the server's upload space is full")
        XCTAssertNotNil(job?.notBefore)
    }
}
