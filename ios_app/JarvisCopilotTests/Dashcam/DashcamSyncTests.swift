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
    var playbackEnterThrows = false
    var gpsCalls: [String] = []
    var gpsThrows = false

    func info() async throws -> DashcamCameraInfo { DashcamCameraInfo(id: "CAM", family: .viidure) }
    func files(timeZone: TimeZone) async throws -> [DashcamFile] {
        calls.append("files")
        if refuseOutsidePlayback && !inPlayback { throw DashcamError.camera("getfilelist: not in playback mode") }
        return files
    }
    func thumbnailURL(_ file: DashcamFile) -> URL? { nil }
    var thumbsMissing = false
    var thumbCalls: [String] = []
    func thumbnail(_ file: DashcamFile) async -> Data? {
        thumbCalls.append(file.path)
        return thumbsMissing ? nil : Data([0xFF, 0xD8] + Array(repeating: 0, count: 200))
    }
    func setTime(_ date: Date, timeZone: TimeZone) async throws { calls.append("time") }
    func isRecording() async throws -> Bool { recordingOn }
    /// The A4 answers "set fail" when asked for the state it's already in.
    var setFailsWhenSame = false
    func setRecording(_ on: Bool) async throws {
        calls.append("rec=\(on)")
        if setFailsWhenSame && recordingOn == on { throw DashcamError.camera("setparamvalue?param=rec&value=1: set fail") }
        recordingOn = on
    }
    func lock() async throws { calls.append("lock") }
    func snapshot() async throws -> String? { nil }
    func settings() async throws -> [DashcamSettingItem] { [] }
    func set(_ name: String, _ value: String) async throws {}
    func sdInfo() async throws -> DashcamSDInfo { DashcamSDInfo(ok: true) }
    func format() async throws {}
    /// Paths deleted from the card, in order.
    var deleted: [String] = []
    /// Some firmware only deletes in playback mode.
    var refuseDeleteOutsidePlayback = false
    /// Paths the camera refuses to delete every time (a protected file).
    var refuseDelete = Set<String>()
    /// Off by default: most fixtures read `files` after a pass.
    var deleteRemovesFile = false
    func delete(_ file: DashcamFile) async throws {
        calls.append("delete=\(file.path)")
        if refuseDelete.contains(file.path) || (refuseDeleteOutsidePlayback && !inPlayback) {
            throw DashcamError.camera("deletefile: refused")
        }
        deleted.append(file.path)
        if deleteRemovesFile { files.removeAll { $0.path == file.path } }
    }
    func setWiFi(ssid: String?, password: String?) async throws {}
    func playback(_ enter: Bool) async throws {
        calls.append("playback=\(enter)")
        inPlayback = enter
        if enter { recordingOn = false }   // the worst case: playback mode pauses recording
        if enter && playbackEnterThrows { throw DashcamError.notConnected }   // switched, but the reply timed out
    }
    func gps(_ file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix] {
        gpsCalls.append(file.path)
        if gpsThrows { throw DashcamError.notConnected }
        return gpsByPath[file.path] ?? []
    }
}

final class FakeSyncServer: DashcamSyncServer, @unchecked Sendable {
    var inventoried: [DashcamFile] = []
    var fixes: [String: Int] = [:]
    var thumbs = Set<String>()
    var phone: [String: String] = [:]
    var uploadedIDs = Set<String>()
    var rules = DashcamRules()
    var unreachable = false
    /// Forgotten by the server (deleted everywhere): their phone-state updates 404.
    var gone = Set<String>()
    /// The card-delete backlog, by clip id; what the phone reported back.
    var backlog: [String: DashcamCardDelete] = [:]
    var marked: [(id: String, forget: Bool)] = []
    var doneIDs: [String] = []
    var failedIDs: [String] = []
    /// Clip ids the server has no record of (mark answers them as missing).
    var unknown = Set<String>()

    func upsertCamera(_ info: DashcamCameraInfo, ssid: String) async throws {}
    func inventory(cameraID: String, files: [DashcamFile]) async throws -> [String: DashcamInventoryRow] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        inventoried = files
        var out: [String: DashcamInventoryRow] = [:]
        for f in files {
            let id = DashcamIDs.clipID(cameraID: cameraID, path: f.path)
            out[f.path] = DashcamInventoryRow(json: ["id": id, "path": f.path, "has_gps": fixes[id] != nil,
                                                     "has_thumb": thumbs.contains(id), "uploaded": uploadedIDs.contains(id),
                                                     "card_delete": backlog[id] != nil])
        }
        return out
    }
    func cardDeletes(cameraID: String) async throws -> [DashcamCardDelete] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        return backlog.values.sorted { $0.id < $1.id }
    }
    func markCardDeletes(_ entries: [(id: String, forget: Bool)]) async throws -> (closed: [String], missing: [String]) {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        marked += entries
        var missing: [String] = []
        for e in entries {
            if unknown.contains(e.id) { missing.append(e.id); continue }
            backlog[e.id] = DashcamCardDelete(id: e.id, path: backlog[e.id]?.path ?? "", forget: e.forget || backlog[e.id]?.forget == true)
        }
        return ([], missing)
    }
    func cardDeletesDone(_ ids: [String]) async throws {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        doneIDs += ids
        for id in ids { backlog[id] = nil }
    }
    func cardDeleteFailed(id: String, error: String) async throws {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        failedIDs.append(id)
    }
    func putFixes(clipID: String, fixes f: [DashcamFix]) async throws { fixes[clipID] = f.count }
    func putThumb(clipID: String, jpeg: Data) async throws { thumbs.insert(clipID) }
    func setPhone(clipID: String, state: String, error: String?) async throws {
        if gone.contains(clipID) { throw APIError.http(status: 404, message: "clip not found") }
        phone[clipID] = state
    }
    func state() async throws -> DashcamServerState {
        DashcamServerState(rules: rules, destinations: [], counts: [:], stagingBytes: 0, stagingCap: 0)
    }
    func updateRules(_ rules: DashcamRules) async throws { self.rules = rules }
    /// What the clip listing answers (the clean-up's "on the phone" page).
    var listed: [DashcamServerClip] = []
    func clips(_ filter: DashcamAPI.ClipFilter, cursor: String?, limit: Int) async throws -> (clips: [DashcamServerClip], next: String?) {
        (listed, nil)
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
    private let lock = NSLock()
    /// Chunks go up three at a time: record them in chunk order.
    private var sentChunks: [(String, Int, Int)] = []
    var chunks: [(String, Int, Int)] { lock.lock(); defer { lock.unlock() }; return sentChunks.sorted { $0.1 < $1.1 } }
    var received: Set<Int> = []
    var full = false
    var completed: [String] = []
    var failChunk: Int?
    var start: DashcamAPI.UploadStart?
    var startCalls = 0
    var completeError: Error?
    func startUpload(clipID: String, size: Int64, sha256: String) async throws -> DashcamAPI.UploadStart {
        startCalls += 1
        if let start { return start }
        if full { return .full(retryAfter: 60) }
        return .ticket(DashcamUploadTicket(uploadID: "u_" + clipID, chunkSize: 4, received: received))
    }
    func sendChunk(uploadID: String, index: Int, data: Data, cellular: Bool,
                   sent: @escaping @Sendable (Int64) -> Void) async throws {
        lock.lock()
        if index == failChunk { failChunk = nil; lock.unlock(); throw URLError(.networkConnectionLost) }
        sentChunks.append((uploadID, index, data.count))
        received.insert(index)
        lock.unlock()
        sent(Int64(data.count))
    }
    func completeUpload(_ uploadID: String) async throws {
        if let completeError { throw completeError }
        completed.append(uploadID)
    }

    // Direct (Drive) uploads.
    var destinations: [DashcamDestination] = []
    var accessError: Error?
    var accessCalls = 0
    var recorded: [String] = []
    var destinationCalls = 0
    var clipInfoError: Error?
    func uploadDestinations() async throws -> [DashcamDestination] {
        destinationCalls += 1
        return destinations
    }
    func driveAccess(destinationID: String) async throws -> DashcamDriveAccess {
        accessCalls += 1
        if let accessError { throw accessError }
        return DashcamDriveAccess(destinationID: destinationID, token: "t", expiresAt: Date().addingTimeInterval(3600),
                                  basePath: "Dashcam", teamDrive: nil)
    }
    func clipInfo(_ clipID: String) async throws -> DashcamServerClip {
        if let clipInfoError { throw clipInfoError }
        return DashcamServerClip(json: ["id": clipID, "path": "/sd/video_front/\(clipID).ts", "camera_id": "CAM", "kind": "normal"])!
    }
    func recordDirect(clipID: String, destinationID: String, remotePath: String, fileID: String, size: Int64,
                      preview: (path: String, fileID: String)?) async throws { recorded.append(clipID) }
}

/// Google Drive without Google: opens a session, then fails or finishes as told.
final class FakeDrive: DashcamDriveClient, @unchecked Sendable {
    var failAfterSession: Error?
    var sessions: [URL?] = []
    func folder(_ path: [String], access: DashcamDriveAccess) async throws -> String { "folder" }
    func existing(name: String, size: Int64, in folder: String, access: DashcamDriveAccess) async throws -> String? { nil }
    func upload(_ file: URL, name: String, mime: String, folder: String, access: DashcamDriveAccess, session: URL?,
                saveSession: @escaping @Sendable (URL) -> Void, sent: @escaping @Sendable (Int64) -> Void) async throws -> String {
        sessions.append(session)
        saveSession(session ?? URL(string: "https://upload.example/session/\(name)")!)
        if let failAfterSession { throw failAfterSession }
        return "file-" + name
    }
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
        sync.defaults = UserDefaults(suiteName: "dashcam-sync-\(UUID().uuidString)")!
        sync.uploader = DashcamUploader(file: root.appendingPathComponent("uploads.json"), tempDir: root.appendingPathComponent("up"),
                                        tombstones: sync.defaults)
        sync.storage = DashcamStorage(root: root)
        sync.cacheBytes = { 0 }
        sync.parked = { [unowned self] in self.parked }
        sync.onCameraProvider = { [unowned self] in self.onCamera }
        sync.timeZone = { TimeZone(secondsFromGMT: 0)! }
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

    /// His A4's GPS module sometimes has no lock: every clip's track is empty. "Reading GPS" sat there.
    func testACameraWithoutAGPSLockDoesNotHoldUpThePass() async {
        cam.files = (0..<12).map { file(.normal, .front, at: TimeInterval($0 * 60)) } + [file(.photo, .front, at: 40, folder: "event")]
        cam.gpsByPath = [:]
        _ = await sync.syncPass()
        XCTAssertLessThanOrEqual(cam.gpsCalls.count, 5, "stops after a run of clips without a fix")
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_40.mp4"), "the photo still comes down")
        let first = cam.gpsCalls
        _ = await sync.syncPass()
        XCTAssertTrue(Set(cam.gpsCalls.dropFirst(first.count)).isDisjoint(with: first), "a clip without a fix isn't read again")
        let remembered = sync.defaults.dictionary(forKey: DashcamSync.noGPSKey) ?? [:]
        XCTAssertTrue(first.allSatisfy { remembered[$0] != nil }, "remembered across launches")
        XCTAssertEqual(cam.gpsCalls.first, "/mnt/card/loop/front_600.mp4", "newest first")
    }

    /// "Fetching thumbnails" sat for minutes: a slow camera or clips without a preview.
    func testClipsWithoutAPreviewDoNotHoldUpThePass() async {
        cam.files = (0..<12).map { file(.normal, .front, at: TimeInterval($0 * 60)) } + [file(.photo, .front, at: 40, folder: "event")]
        cam.thumbsMissing = true
        _ = await sync.syncPass()
        XCTAssertLessThanOrEqual(cam.thumbCalls.count, 3, "stops after three misses in a row")
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_40.mp4"), "the photo still comes down")
        let first = cam.thumbCalls
        _ = await sync.syncPass()
        XCTAssertTrue(Set(cam.thumbCalls.dropFirst(first.count)).isDisjoint(with: first), "a miss isn't asked again")
        XCTAssertNotNil(sync.defaults.dictionary(forKey: DashcamSync.noThumbKey), "remembered across launches")
    }

    func testGPSErrorsDoNotHoldUpThePass() async {
        cam.files = (0..<12).map { file(.normal, .front, at: TimeInterval($0 * 60)) } + [file(.photo, .front, at: 40, folder: "event")]
        cam.gpsThrows = true
        _ = await sync.syncPass()
        XCTAssertLessThanOrEqual(cam.gpsCalls.count, 3)
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_40.mp4"))
        XCTAssertNil(sync.defaults.dictionary(forKey: DashcamSync.noGPSKey), "an error isn't 'no fix': tried again later")
    }

    func testNormalFootageFollowsTheRulesAndFetchRangeForcesIt() async {
        var rules = DashcamRules(); rules.normal = .front
        server.rules = rules            // rules come from the server every pass
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("front_0.mp4"))
        XCTAssertFalse(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"))
        // Jarvis asks for the rear clip around t=0..30 explicitly.
        let n = await sync.fetch(from: Date(timeIntervalSince1970: 1_790_000_000), to: Date(timeIntervalSince1970: 1_790_000_010))
        XCTAssertEqual(n, 1, "front_0 already came down and left the card: only rear_0 is still there")
        XCTAssertTrue(cam.deleted.contains { $0.hasSuffix("front_0.mp4") })
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"))
    }

    /// A clip he tagged while it was only on the camera comes off it whatever the rules say — after a
    /// relaunch too (the camera records over old footage).
    func testATaggedClipOnTheCameraIsPulledWhateverTheRules() async {
        var rules = DashcamRules(); rules.normal = .front
        server.rules = rules
        let rear = cam.files.first { $0.lens == .rear && $0.start.timeIntervalSince1970 == 1_790_000_000 }!
        DashcamTagged.mark(DashcamIDs.clipID(cameraID: "CAM", path: rear.path), defaults: sync.defaults)
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"))
        XCTAssertFalse(fetcher.fetched.map(\.lastPathComponent).contains("rear_60.mp4"), "untagged rear: the rules")
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
        server.rules = rules
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

    func testALeftoverPlaybackModeIsExitedFirstAndRecordingRestored() async {
        sync.defaults.set(true, forKey: DashcamSync.playbackFlagKey)
        cam.inPlayback = true
        cam.recordingOn = false
        _ = await sync.syncPass()
        let exitIndex = cam.calls.firstIndex(of: "playback=false")
        XCTAssertNotNil(exitIndex)
        XCTAssertLessThan(exitIndex!, cam.calls.firstIndex(of: "files")!, "exits before anything else")
        XCTAssertTrue(cam.recordingOn)
        XCTAssertFalse(sync.defaults.bool(forKey: DashcamSync.playbackFlagKey))
    }

    func testAnEmptyCardNeverTriggersPlaybackMode() async {
        cam.files = []
        parked = true
        _ = await sync.syncPass()
        XCTAssertFalse(cam.calls.contains("playback=true"))
        XCTAssertEqual(sync.phase, .idle)
    }

    func testARefusalWhileDrivingWaitsAndLearnsNothing() async {
        cam.refuseOutsidePlayback = true
        var saved: [DashcamSetup] = []
        sync.setupStore = { saved.append($0) }
        _ = await sync.syncPass()
        XCTAssertEqual(sync.phase, .waitingForPark)
        XCTAssertTrue(saved.isEmpty, "a refusal alone doesn't mark the camera playback-only")
        XCTAssertFalse(sync.defaults.bool(forKey: DashcamSync.playbackFlagKey))
    }

    func testDrivingOffMidPassStopsWorkAndRestoresRecording() async {
        cam.refuseOutsidePlayback = true
        var checks = 0
        sync.parked = { checks += 1; return checks <= 2 }   // parked to enter, then the car moves
        let report = await sync.syncPass()
        XCTAssertTrue(report.usedPlayback)
        XCTAssertTrue(cam.calls.contains("playback=false"))
        XCTAssertTrue(cam.recordingOn)
        XCTAssertLessThan(fetcher.fetched.count, 2, "stopped as soon as the car moved")
    }

    func testAPlaybackEntryThatTimesOutIsStillExited() async {
        cam.refuseOutsidePlayback = true
        cam.playbackEnterThrows = true
        parked = true
        _ = await sync.syncPass()
        XCTAssertTrue(cam.calls.contains("playback=false"))
        XCTAssertFalse(cam.inPlayback)
        XCTAssertTrue(cam.recordingOn)
    }

    func testDuplicatePathsFromTheFirmwareDoNotCrash() async {
        cam.files += cam.files
        let report = await sync.syncPass()
        XCTAssertEqual(report.listed, 7)
        _ = await sync.syncPass()
    }

    func testAClipWithoutGPSIsNotReadEveryPass() async {
        cam.gpsByPath[cam.files[0].path] = []
        _ = await sync.syncPass()
        _ = await sync.syncPass()
        XCTAssertEqual(cam.gpsCalls.filter { $0 == cam.files[0].path }.count, 1)
    }

    func testFetchRangesSurviveARelaunch() async {
        onCamera = false
        _ = await sync.fetch(from: Date(timeIntervalSince1970: 1_790_000_000), to: Date(timeIntervalSince1970: 1_790_000_010))
        let relaunched = DashcamSync()
        relaunched.defaults = sync.defaults
        relaunched.setupProvider = sync.setupProvider
        relaunched.cameraFactory = { [unowned self] _ in self.cam }
        relaunched.server = server
        relaunched.fetcher = fetcher
        relaunched.uploader = DashcamUploader(file: root.appendingPathComponent("uploads2.json"))
        relaunched.storage = DashcamStorage(root: root)
        relaunched.parked = { false }
        relaunched.onCameraProvider = { true }
        relaunched.timeZone = { TimeZone(secondsFromGMT: 0)! }
        relaunched.now = { Date(timeIntervalSince1970: 1_790_010_000) }
        _ = await relaunched.syncPass()
        XCTAssertTrue(fetcher.fetched.map(\.lastPathComponent).contains("rear_0.mp4"), "asked for while away, pulled after relaunch")
    }

    // MARK: Deleted clips stay deleted

    // MARK: Deleting from the card

    private func id(_ f: DashcamFile) -> String { DashcamIDs.clipID(cameraID: "CAM", path: f.path) }

    func testEachDownloadIsDeletedFromTheCardRightAfter() async {
        var deletedBeforeFetch: [String: Int] = [:]
        let cam = self.cam!, fetcher = self.fetcher!
        fetcher.onFetch = { if let name = fetcher.fetched.last?.lastPathComponent { deletedBeforeFetch[name] = cam.deleted.count } }
        let report = await sync.syncPass()
        XCTAssertEqual(Set(cam.deleted), Set(report.downloaded), "every download leaves the card, nothing else does")
        XCTAssertEqual(report.downloaded.count, 2)
        // One at a time: the first clip was already off the card when the second came down.
        XCTAssertEqual(deletedBeforeFetch.values.sorted(), [0, 1])
        XCTAssertEqual(Set(report.cardDeleted), Set(report.downloaded))
    }

    func testTheSweepDeletesClipsAlreadyUploaded() async {
        let old = cam.files[0]                       // normal footage, not pulled by default, but in the cloud
        server.uploadedIDs = [id(old)]
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(old.path))
    }

    func testTheSweepDeletesClipsAlreadyOnThePhone() async throws {
        let old = cam.files[0]
        let url = sync.storage.localURL(camera: "CAM", file: old)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(old.path))
    }

    func testTheSweepLeavesClipsThatAreOnlyOnTheCard() async {
        let tagged = cam.files[0]
        DashcamTagged.mark(id(tagged), defaults: sync.defaults)
        fetcher.failAfter = 0                        // nothing comes down
        _ = await sync.syncPass()
        XCTAssertEqual(cam.deleted, [], "only on the card: never deleted, tagged or not")
    }

    func testATombstonedDownloadIsNotDeletedFromTheCard() async {
        let defaults = sync.defaults, id = eventID, name = eventClip.name, fetcher = self.fetcher!
        fetcher.onFetch = { if fetcher.fetched.last?.lastPathComponent == name { DashcamTombstones.add(id, defaults: defaults) } }
        _ = await sync.syncPass()
        XCTAssertFalse(cam.deleted.contains(eventClip.path))
    }

    func testAShortDownloadIsNotDeletedFromTheCard() async {
        cam.files = [DashcamFile(path: "/mnt/card/emr/front_30.mp4", kind: .event, lens: .front,
                                 start: Date(timeIntervalSince1970: 1_790_000_030), durationS: 60, size: 50_000, folder: "emr")]
        _ = await sync.syncPass()                    // the fake writes 10 bytes: far short of the listing
        XCTAssertEqual(cam.deleted, [])
    }

    func testBacklogFromTheServerIsFlushedAndReportedDone() async {
        let asked = cam.files[1]
        server.backlog[id(asked)] = DashcamCardDelete(id: id(asked), path: asked.path, forget: true)
        let report = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(asked.path))
        XCTAssertEqual(server.doneIDs, [id(asked)])
        XCTAssertFalse(server.inventoried.contains { $0.path == asked.path }, "deleted: the server hears it's gone")
        XCTAssertFalse(report.downloaded.contains(asked.path))
    }

    func testARefusedBacklogDeleteStaysListedForTheServer() async {
        let asked = eventClip
        server.backlog[id(asked)] = DashcamCardDelete(id: id(asked), path: asked.path, forget: false)
        cam.refuseDelete = [asked.path]
        let report = await sync.syncPass()
        XCTAssertTrue(server.inventoried.contains { $0.path == asked.path }, "still on the card: the entry must stay open")
        XCTAssertEqual(server.failedIDs, [id(asked)])
        XCTAssertTrue(server.doneIDs.isEmpty)
        XCTAssertFalse(report.downloaded.contains(asked.path), "asked to be deleted: never pulled")
    }

    func testABacklogEntryNoLongerOnTheCardIsDone() async {
        let gone = "/mnt/card/loop/front_999.mp4"
        server.backlog[DashcamIDs.clipID(cameraID: "CAM", path: gone)] =
            DashcamCardDelete(id: DashcamIDs.clipID(cameraID: "CAM", path: gone), path: gone, forget: false)
        _ = await sync.syncPass()
        XCTAssertEqual(server.doneIDs, [DashcamIDs.clipID(cameraID: "CAM", path: gone)])
    }

    func testOldLocalQueueMigratesToTheServer() async {
        let asked = cam.files[2]
        sync.defaults.setValue([asked.path], forKey: DashcamSync.cameraDeletesKey)
        cam.refuseDelete = [asked.path]              // so it stays queued
        _ = await sync.syncPass()
        XCTAssertTrue(server.marked.contains { $0.id == id(asked) && !$0.forget })
        XCTAssertNil(sync.defaults.stringArray(forKey: DashcamSync.cameraDeletesKey), "the old list is gone")
        XCTAssertEqual(sync.pendingCameraDeletes, [asked.path: false], "kept on the new list until the camera does it")
    }

    func testADeleteAskedAwayWaitsOnTheServerAndThePhone() async {
        onCamera = false
        let asked = cam.files[1]
        let now = await sync.deleteFromCamera(asked.path, clipID: id(asked), forget: true)
        XCTAssertFalse(now)
        XCTAssertTrue(server.marked.contains { $0.id == id(asked) && $0.forget })
        XCTAssertEqual(sync.pendingCameraDeletes[asked.path], true)
        onCamera = true
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(asked.path))
        XCTAssertTrue(sync.pendingCameraDeletes.isEmpty)
        XCTAssertTrue(server.doneIDs.contains(id(asked)))
    }

    func testDeleteFromTheDashcamAwayWaitsMarkedWithTheClipsID() async throws {
        onCamera = false
        let f = cam.files[1]
        let clip = try XCTUnwrap(DashcamServerClip(json: ["id": "c_server_id", "camera_id": "CAM", "path": f.path, "on_camera": true]))
        let (done, failed) = await DashcamClipActions.delete(clip, [.camera], sync: sync)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(done, ["dashcam (pending — deletes when next connected)"])
        XCTAssertEqual(server.marked.map(\.id), ["c_server_id"], "the server's own id for the clip")
        XCTAssertEqual(server.marked.map(\.forget), [false])
    }

    func testPlaybackDeleteRetryStopsAfterThreeFailures() async {
        let stuck = cam.files[0]
        server.uploadedIDs = [id(stuck)]
        cam.refuseDelete = [stuck.path]
        parked = true
        var passesInPlayback = 0
        for _ in 0..<4 {
            cam.calls = []
            _ = await sync.syncPass()
            if cam.calls.contains("playback=true") { passesInPlayback += 1 }
        }
        XCTAssertEqual(passesInPlayback, 3)
        XCTAssertFalse(cam.inPlayback, "always left playback mode")
    }

    func testPlaybackOnlyFirmwareDeletesWhileParkedNeverWhileDriving() async {
        cam.refuseDeleteOutsidePlayback = true
        parked = false
        let report = await sync.syncPass()
        XCTAssertFalse(cam.calls.contains("playback=true"), "never playback mode while driving")
        XCTAssertEqual(cam.deleted, [])
        parked = true
        _ = await sync.syncPass()
        XCTAssertEqual(Set(cam.deleted), Set(report.downloaded), "the sweep clears them once parked")
        XCTAssertTrue(cam.recordingOn, "recording restored")
    }

    private var eventClip: DashcamFile { cam.files.first { $0.kind == .event }! }
    private var eventID: String { DashcamIDs.clipID(cameraID: "CAM", path: eventClip.path) }

    /// The Oct 3 / Oct 9 race: he deleted a clip everywhere while its download was still running. It landed
    /// seconds later, was queued, and asked the server to upload it every 10 minutes for a week.
    func testAClipDeletedWhileItDownloadsIsDiscardedWhenItLands() async {
        let defaults = sync.defaults, id = eventID, name = eventClip.name, fetcher = self.fetcher!
        fetcher.onFetch = { if fetcher.fetched.last?.lastPathComponent == name { DashcamTombstones.add(id, defaults: defaults) } }
        let report = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == name }, "its download was already running")
        XCTAssertFalse(report.downloaded.contains(eventClip.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.storage.localURL(camera: "CAM", file: eventClip).path))
        let queued = await sync.uploader.jobs.map(\.clipID)
        XCTAssertFalse(queued.contains(id), "never queued")
        XCTAssertEqual(queued.count, 1, "the photo still goes")
    }

    /// Deleted everywhere from somewhere else (the web): the server forgot it during the download.
    func testAClipTheServerForgotDuringItsDownloadIsDiscardedAndRemembered() async {
        let server = self.server!, id = eventID, name = eventClip.name, fetcher = self.fetcher!
        fetcher.onFetch = { if fetcher.fetched.last?.lastPathComponent == name { server.gone.insert(id) } }
        _ = await sync.syncPass()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.storage.localURL(camera: "CAM", file: eventClip).path))
        XCTAssertTrue(DashcamTombstones.contains(id, defaults: sync.defaults))
        let queued = await sync.uploader.jobs.map(\.clipID)
        XCTAssertFalse(queued.contains(id))
    }

    /// The inventory failed (LTE on the camera's Wi‑Fi), so the server hasn't heard of the clip yet:
    /// its "clip not found" is not a delete, and fresh footage must never be thrown away for it.
    func testAClipTheServerHasNotListedYetIsKept() async {
        server.unreachable = true
        server.gone = [eventID]
        _ = await sync.syncPass()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sync.storage.localURL(camera: "CAM", file: eventClip).path))
        XCTAssertFalse(DashcamTombstones.contains(eventID, defaults: sync.defaults))
        let id = eventID
        let job = await sync.uploader.jobs.first { $0.clipID == id }
        XCTAssertEqual(job?.unconfirmed, true, "a 404 for it later means 'not yet', until an inventory lists it")
    }

    func testAPassNeverPullsAClipDeletedHereUnlessPulledByHand() async {
        DashcamTombstones.add(eventID, defaults: sync.defaults)
        _ = await sync.syncPass()
        XCTAssertFalse(fetcher.fetched.contains { $0.lastPathComponent == self.eventClip.name })
        // "Download again" (passSoon is skipped off the camera's Wi‑Fi; the pass below takes it).
        onCamera = false
        sync.pull(eventClip.path)
        onCamera = true
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == self.eventClip.name })
        XCTAssertFalse(DashcamTombstones.contains(eventID, defaults: sync.defaults))
    }

    /// A clip he tagged stays on the phone once it's uploaded everywhere; an untagged one goes, as before.
    func testATaggedClipStaysOnThePhoneAfterUpload() async throws {
        func local(_ t: TimeInterval) throws -> (URL, DashcamServerClip, Bool) {
            let f = file(.normal, .front, at: t)
            let same = DashcamFile(path: f.path, kind: .normal, lens: .front, start: f.start, durationS: 60, size: 10)
            let url = sync.storage.localURL(camera: "CAM", file: same)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 10).write(to: url)
            let tagged = t == 0
            let clip = DashcamServerClip(json: ["id": DashcamIDs.clipID(cameraID: "CAM", path: f.path), "camera_id": "CAM",
                                                "path": f.path, "kind": "normal", "lens": "front", "start": f.start.dashcamISO,
                                                "duration_s": 60, "size": 10, "phone": ["state": "local"],
                                                "upload": ["state": "done"], "uploaded": true,
                                                "tags": tagged ? ["accident"] : []])!
            return (url, clip, tagged)
        }
        let rows = [try local(0), try local(60)]
        server.listed = rows.map(\.1)
        await sync.cleanUpUploaded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rows[0].0.path), "tagged: kept on the phone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rows[1].0.path), "untagged: gone once uploaded")
        XCTAssertTrue(DashcamTagged.contains(rows[0].1.id, defaults: sync.defaults))
        XCTAssertFalse(DashcamTagged.contains(rows[1].1.id, defaults: sync.defaults))
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

    func testStoredPathsReanchorAfterAReinstall() throws {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        let file = docs.appendingPathComponent("Dashcam/cam/event/front/a.mp4")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let old = "/private/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Dashcam/cam/event/front/a.mp4"
        XCTAssertEqual(DashcamUploader.resolve(old, documents: docs), file.path)
    }

    func testADownloadedAgainClipReplacesItsJob() async throws {
        let a = try tempFile(4)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "c", local: a, size: 3, kind: .event)
        await uploader.enqueue(clipID: "c", local: a, size: 4, kind: .event)
        let jobs = await uploader.jobs
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.size, 4)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tsFile(_ name: String = "clip_f.ts") throws -> URL {
        let url = try tempDir().appendingPathComponent(name)
        try Data(count: 64).write(to: url)
        return url
    }

    private static let drive = DashcamDestination(json: ["id": "d_1", "type": "drive", "name": "Drive"])!

    /// His Drive sign-in died on day 7 and 126 clips kept asking the server — each attempt costing a
    /// conversion (a second copy of the clip) — while the phone filled up.
    func testAnExpiredDriveSignInHoldsItsUploadsWithoutConvertingAnything() async throws {
        let temp = try tempDir()
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), drive: FakeDrive(), tempDir: temp)
        await uploader.enqueue(clipID: "a", local: try tsFile(), size: 64, kind: .normal)
        await uploader.enqueue(clipID: "b", local: try tsFile(), size: 64, kind: .normal)
        let server = FakeUploadServer()
        server.destinations = [Self.drive]
        server.accessError = DashcamDriveError.signInExpired("d_1")
        let clock = Date(timeIntervalSince1970: 1000)
        let none = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(server.accessCalls, 1, "the second clip doesn't ask again")
        let jobs = await uploader.jobs
        XCTAssertEqual(jobs.map(\.attempts), [0, 0], "no clip used up its retries")
        XCTAssertEqual(jobs.first?.lastError, DashcamDriveError.signInExpired("d_1").localizedDescription)
        let held = await uploader.expiredSignIns(now: clock)
        XCTAssertEqual(held, ["d_1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [], "nothing converted")
        _ = await uploader.run(server: server, cellular: false, now: { clock.addingTimeInterval(60) })
        XCTAssertEqual(server.accessCalls, 1, "still held")
        // Signed in again (Destinations → destinationsChanged → retryParked): everything goes.
        server.accessError = nil
        await uploader.retryParked()
        let sent = await uploader.run(server: server, cellular: false, now: { clock.addingTimeInterval(120) })
        XCTAssertEqual(Set(sent), ["a", "b"])
        XCTAssertEqual(Set(server.recorded), ["a", "b"])
    }

    /// 130 GB of the phone: converted copies of uploads long gone, and the converter's own leftovers.
    func testTheUploadFolderKeepsOnlyACopyGoogleIsHalfwayThrough() async throws {
        let temp = try tempDir()
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), drive: FakeDrive(), tempDir: temp)
        await uploader.enqueue(clipID: "queued", local: try tsFile(), size: 64, kind: .normal)
        for name in ["queued.mp4", "gone.mp4", "x.preview.mp4", ".c_1.mp4.part.sb-742ce9cd-Zb9xEk"] {
            try Data(count: 10).write(to: temp.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: temp.appendingPathComponent(".remux-old"), withIntermediateDirectories: true)
        await uploader.sweepTemp()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted(), [],
                       "a queued clip with no Google session is converted again when its turn comes")
    }

    /// A dropped Drive upload used to forget its session (the run wrote back a stale job), so every retry
    /// started from byte 0 — and the copy it resumes from must stay while the session does.
    func testADroppedDriveUploadKeepsItsSessionAndItsCopy() async throws {
        let temp = try tempDir()
        let drive = FakeDrive()
        drive.failAfterSession = URLError(.networkConnectionLost)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), drive: drive, tempDir: temp)
        let mp4 = try tempDir().appendingPathComponent("clip.mp4")
        try Data(count: 64).write(to: mp4)
        await uploader.enqueue(clipID: "a", local: mp4, size: 64, kind: .normal)
        let server = FakeUploadServer()
        server.destinations = [Self.drive]
        var clock = Date(timeIntervalSince1970: 1000)
        _ = await uploader.run(server: server, cellular: false, now: { clock })
        let job = await uploader.jobs.first
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertNotNil(job?.directSessions?["d_1"], "the session survives the failure")
        drive.failAfterSession = nil
        clock = clock.addingTimeInterval(31)
        let done = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertEqual(done, ["a"])
        XCTAssertEqual(drive.sessions.last ?? nil, URL(string: "https://upload.example/session/a.ts"), "resumed, not restarted")
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

    /// He connected Drive after 69 clips were refused for "no destination"; nothing went up after.
    func testAddingADestinationWakesClipsParkedOnNoDestination() async throws {
        let a = try tempFile(4)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "a", local: a, size: 4, kind: .normal)
        let server = FakeUploadServer()
        server.start = .noDestination
        _ = await uploader.run(server: server, cellular: false)
        let parked = await uploader.jobs.first?.notBefore
        XCTAssertNotNil(parked)
        XCTAssertLessThanOrEqual(parked ?? .distantFuture, Date().addingTimeInterval(301), "a short park, not an hour")
        server.start = .alreadyThere
        let stillParked = await uploader.run(server: server, cellular: false)
        XCTAssertTrue(stillParked.isEmpty, "still parked")
        await uploader.retryParked()
        let woken = await uploader.run(server: server, cellular: false)
        XCTAssertEqual(woken, ["a"])
    }

    func testTheUploadRulesDecideWhatGoesOverMobileData() async throws {
        let n = try tempFile(4)
        let uploader = DashcamUploader(file: FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json"))
        await uploader.enqueue(clipID: "n", local: n, size: 4, kind: .normal)
        let server = FakeUploadServer()
        var rules = DashcamRules()
        rules.uploadData = .events
        let frozen = rules
        let held = await uploader.run(server: server, cellular: true, allow: { frozen.mayUpload($0, metered: true, parked: true) })
        XCTAssertTrue(held.isEmpty)
        rules.uploadData = .all
        let open = rules
        let sent = await uploader.run(server: server, cellular: true, allow: { open.mayUpload($0, metered: true, parked: true) })
        XCTAssertEqual(sent, ["n"], "LTE on the camera's Wi‑Fi carries normal footage when the rules say so")
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

    // MARK: Deleted clips, and waiting without asking

    private func suite() -> UserDefaults { UserDefaults(suiteName: "dashcam-up-\(UUID().uuidString)")! }

    /// He deleted two clips everywhere while their downloads ran; the server said "clip not found" on every
    /// retry for a week. Now the first answer ends it: the job and the phone's copy go, and it stays deleted.
    func testAClipTheServerNoLongerHasIsDroppedWithItsPhoneCopy() async throws {
        let tombstones = suite()
        let url = try tempFile(4)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: tombstones)
        await uploader.enqueue(clipID: "gone", local: url, size: 4, kind: .event)
        let server = FakeUploadServer()
        server.start = .clipGone
        let done = await uploader.run(server: server, cellular: false)
        XCTAssertTrue(done.isEmpty)
        let jobs = await uploader.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the phone's copy goes too")
        XCTAssertTrue(DashcamTombstones.contains("gone", defaults: tombstones))
        try Data([1]).write(to: url)
        await uploader.enqueue(clipID: "gone", local: url, size: 1, kind: .event)
        let again = await uploader.jobs
        XCTAssertTrue(again.isEmpty, "never queued again")
    }

    func testADeletedClipBoundForDriveIsDroppedToo() async throws {
        let tombstones = suite()
        let mp4 = try tempDir().appendingPathComponent("clip.mp4")
        try Data(count: 64).write(to: mp4)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), drive: FakeDrive(),
                                       tempDir: try tempDir(), tombstones: tombstones)
        await uploader.enqueue(clipID: "gone", local: mp4, size: 64, kind: .normal)
        let server = FakeUploadServer()
        server.destinations = [Self.drive]
        server.clipInfoError = APIError.http(status: 404, message: "clip not found")
        let done = await uploader.run(server: server, cellular: false)
        XCTAssertTrue(done.isEmpty)
        let jobs = await uploader.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp4.path))
        XCTAssertTrue(DashcamTombstones.contains("gone", defaults: tombstones))
        XCTAssertTrue(server.recorded.isEmpty)
    }

    /// "upload not found" means the server dropped the upload's chunks, not the clip: it starts over.
    func testAnUploadTheServerLostIsRetriedNotDeleted() async throws {
        let tombstones = suite()
        let url = try tempFile(8)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: tombstones)
        await uploader.enqueue(clipID: "c1", local: url, size: 8, kind: .event)
        let server = FakeUploadServer()
        server.completeError = APIError.http(status: 404, message: "upload not found")
        let clock = Date(timeIntervalSince1970: 1000)
        let first = await uploader.run(server: server, cellular: false, now: { clock })
        XCTAssertTrue(first.isEmpty)
        let job = await uploader.jobs.first
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(DashcamTombstones.contains("c1", defaults: tombstones))
        server.completeError = nil
        let later = await uploader.run(server: server, cellular: false, now: { clock.addingTimeInterval(31) })
        XCTAssertEqual(later, ["c1"])
    }

    /// Queued while the server hadn't heard of the clip (its inventory failed): a 404 is "not yet".
    func testANotYetListedClipWaitsInsteadOfBeingDeleted() async throws {
        let tombstones = suite()
        let url = try tempFile(4)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: tombstones)
        await uploader.enqueue(clipID: "new", local: url, size: 4, kind: .event, confirmed: false)
        let server = FakeUploadServer()
        server.start = .clipGone
        let clock = Date(timeIntervalSince1970: 1000)
        _ = await uploader.run(server: server, cellular: false, now: { clock })
        let job = await uploader.jobs.first
        XCTAssertEqual(job?.attempts, 1, "an ordinary retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(DashcamTombstones.contains("new", defaults: tombstones))
        await uploader.confirm(["new"])                 // the next inventory listed it
        _ = await uploader.run(server: server, cellular: false, now: { clock.addingTimeInterval(31) })
        let left = await uploader.jobs
        XCTAssertTrue(left.isEmpty, "listed, then gone: deleted")
        XCTAssertTrue(DashcamTombstones.contains("new", defaults: tombstones))
    }

    func testAClipDeletedHereIsNeverQueued() async throws {
        let tombstones = suite()
        DashcamTombstones.add("c", defaults: tombstones)
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: tombstones)
        await uploader.enqueue(clipID: "c", local: try tempFile(4), size: 4, kind: .event)
        let jobs = await uploader.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    /// A queue saved with these retry times (the uploader reloads it at launch).
    private func savedQueue(_ times: [String: TimeInterval?], kind: DashcamClipKind = .event, now: Date) throws -> URL {
        let jobs = times.keys.sorted().map { id -> DashcamUploadJob in
            var job = DashcamUploadJob(clipID: id, localPath: "/nowhere/\(id).mp4", size: 1, kind: kind)
            job.notBefore = times[id]!.map { now.addingTimeInterval($0) }
            return job
        }
        let file = try tempDir().appendingPathComponent("q.json")
        try JSONEncoder().encode(jobs).write(to: file)
        return file
    }

    /// The loop sleeps until the earliest retry still ahead — not one already past, not one far off.
    func testNextDueIsTheEarliestRetryStillAhead() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let file = try savedQueue(["past": -10, "later": 600, "soon": 120, "free": nil], now: now)
        let uploader = DashcamUploader(file: file, tombstones: suite())
        let due = await uploader.nextDue(now: now)
        XCTAssertEqual(due, now.addingTimeInterval(120))
        let empty = DashcamUploader(file: try tempDir().appendingPathComponent("none.json"), tombstones: suite())
        let none = await empty.nextDue(now: now)
        XCTAssertNil(none, "nothing waits on the clock")
    }

    /// Two clips that could never go had the loop asking for the destinations 231 times an hour all night.
    func testARunWithNothingAllowedNowMakesNoRequest() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let server = FakeUploadServer()
        let backingOff = DashcamUploader(file: try savedQueue(["a": 60, "b": 600], now: now), tombstones: suite())
        let none = await backingOff.run(server: server, cellular: false, now: { now })
        XCTAssertTrue(none.isEmpty)
        let normalOnLTE = DashcamUploader(file: try savedQueue(["n": nil], kind: .normal, now: now), tombstones: suite())
        _ = await normalOnLTE.run(server: server, cellular: true, now: { now })
        XCTAssertEqual(server.destinationCalls, 0)
        XCTAssertEqual(server.startCalls, 0)
    }

    func testDestinationsAreAskedForOnceUntilSomethingSaysTheyChanged() async throws {
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: suite())
        let server = FakeUploadServer()
        await uploader.enqueue(clipID: "a", local: try tempFile(4), size: 4, kind: .event)
        _ = await uploader.run(server: server, cellular: false)
        await uploader.enqueue(clipID: "b", local: try tempFile(4), size: 4, kind: .event)
        let second = await uploader.run(server: server, cellular: false)
        XCTAssertEqual(second, ["b"])
        XCTAssertEqual(server.destinationCalls, 1, "kept between runs")
        await uploader.invalidateDestinations()          // a push, foreground, a sign-in error
        await uploader.enqueue(clipID: "c", local: try tempFile(4), size: 4, kind: .event)
        _ = await uploader.run(server: server, cellular: false)
        XCTAssertEqual(server.destinationCalls, 2)
    }
}
