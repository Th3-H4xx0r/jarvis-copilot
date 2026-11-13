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
    func format() async throws { calls.append("format") }
    /// Paths deleted from the card, in order.
    var deleted: [String] = []
    /// Some firmware only deletes in playback mode.
    var refuseDeleteOutsidePlayback = false
    /// Paths the camera refuses to delete every time (a protected file).
    var refuseDelete = Set<String>()
    /// Off by default: most fixtures read `files` after a pass.
    var deleteRemovesFile = false
    /// Runs as each delete is asked for (before the camera answers): a test can tag another clip mid-sweep.
    var onDelete: ((DashcamFile) -> Void)?
    func delete(_ file: DashcamFile) async throws {
        calls.append("delete=\(file.path)")
        onDelete?(file)
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
    /// Clip ids the server calls locked (tagged) in its inventory rows.
    var lockedIDs = Set<String>()
    /// Clip ids a card-delete ask comes back neither queued, missing nor locked for.
    var unmarked = Set<String>()

    func upsertCamera(_ info: DashcamCameraInfo, ssid: String) async throws {}
    func inventory(cameraID: String, files: [DashcamFile]) async throws -> [String: DashcamInventoryRow] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        let before = Dictionary(inventoried.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        inventoried = files
        var out: [String: DashcamInventoryRow] = [:]
        for f in files {
            let id = DashcamIDs.clipID(cameraID: cameraID, path: f.path)
            let stable = before[f.path] == f.size
            out[f.path] = DashcamInventoryRow(json: ["id": id, "path": f.path, "has_gps": fixes[id] != nil,
                                                     "has_thumb": thumbs.contains(id), "uploaded": uploadedIDs.contains(id),
                                                     "card_delete": backlog[id] != nil, "size_stable": stable,
                                                     "locked": lockedIDs.contains(id)])
        }
        return out
    }
    func cardDeletes(cameraID: String) async throws -> [DashcamCardDelete] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        return backlog.values.sorted { $0.id < $1.id }
    }
    func markCardDeletes(_ entries: [(id: String, forget: Bool)]) async throws -> DashcamCardMarks {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        marked += entries
        var answer = DashcamCardMarks(marked: [])
        for e in entries {
            if unknown.contains(e.id) { answer.missing.append(e.id); continue }
            if lockedIDs.contains(e.id) { answer.locked.append(e.id); continue }     // a tagged clip is never queued
            if unmarked.contains(e.id) { continue }
            backlog[e.id] = DashcamCardDelete(id: e.id, path: backlog[e.id]?.path ?? "", forget: e.forget || backlog[e.id]?.forget == true)
            answer.marked?.append(e.id)
        }
        return answer
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
    /// What the clip listing answers (the clean-up's "on the phone" page; a tag's clips when asked by tag).
    var listed: [DashcamServerClip] = []
    func clips(_ filter: DashcamAPI.ClipFilter, cursor: String?, limit: Int) async throws -> (clips: [DashcamServerClip], next: String?) {
        if let tag = filter.tag { return (listed.filter { $0.tags.contains(tag) }, nil) }
        return (listed, nil)
    }
    func tags() async throws -> [DashcamTag] {
        if unreachable { throw APIError.http(status: 502, message: "down") }
        return DashcamTag.presets
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
        sync.restoreSources = { _ in [] }               // never the real Drive or server
        sync.freeSpace = { 100_000_000_000 }
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
        XCTAssertGreaterThanOrEqual(n, 2, "front_0 came down but its size hasn't held over two listings: still on the card")
        XCTAssertFalse(cam.deleted.contains { $0.hasSuffix("front_0.mp4") })
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
        fetcher.failAfter = 0
        _ = await sync.syncPass()                     // listed once: sizes known
        XCTAssertEqual(cam.deleted, [])
        fetcher.failAfter = nil
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
        XCTAssertFalse(cam.deleted.contains(old.path), "one listing: its size hasn't held yet")
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(old.path))
    }

    /// Parking mode can report "not recording" while a clip still grows: a changed size is never deleted.
    func testAClipStillGrowingIsNeverDeletedFromTheCard() async {
        cam.recordingOn = false
        let growing = cam.files[0]
        server.uploadedIDs = [id(growing)]
        _ = await sync.syncPass()
        cam.files[0] = DashcamFile(path: growing.path, kind: growing.kind, lens: growing.lens, start: growing.start,
                                   durationS: growing.durationS, size: growing.size + 100, folder: growing.folder)
        _ = await sync.syncPass()
        XCTAssertFalse(cam.deleted.contains(growing.path))
    }

    func testThePlaybackBatchStopsWhenTheCarDrivesOff() async {
        cam.refuseDeleteOutsidePlayback = true
        for f in cam.files { server.uploadedIDs.insert(id(f)) }
        _ = await sync.syncPass()                     // sizes known
        parked = true
        let parkedFlag = { [unowned self] in self.parked }
        var checks = 0
        sync.parked = { [unowned self] in
            checks += 1
            if self.cam.inPlayback && !self.cam.deleted.isEmpty { self.parked = false }   // drives off after the first
            return parkedFlag()
        }
        _ = await sync.syncPass()
        XCTAssertEqual(cam.deleted.count, 1, "stops at the next file once moving")
        XCTAssertFalse(cam.inPlayback)
        XCTAssertTrue(cam.recordingOn)
        XCTAssertGreaterThan(checks, 1)
    }

    func testTheSweepDeletesClipsAlreadyOnThePhone() async throws {
        let old = cam.files[0]
        let url = sync.storage.localURL(camera: "CAM", file: old)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        _ = await sync.syncPass()
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

    /// A listing can come back short: one miss proves nothing, two passes in a row close it.
    func testABacklogEntryNoLongerOnTheCardIsDoneAfterTwoPasses() async {
        let gone = "/mnt/card/loop/front_999.mp4"
        server.backlog[DashcamIDs.clipID(cameraID: "CAM", path: gone)] =
            DashcamCardDelete(id: DashcamIDs.clipID(cameraID: "CAM", path: gone), path: gone, forget: false)
        _ = await sync.syncPass()
        XCTAssertEqual(server.doneIDs, [], "one short listing must not close it")
        _ = await sync.syncPass()
        XCTAssertEqual(server.doneIDs, [DashcamIDs.clipID(cameraID: "CAM", path: gone)])
    }

    func testABacklogPathListedAgainStartsCountingOver() async {
        let asked = cam.files[1]
        let cid = id(asked)
        server.backlog[cid] = DashcamCardDelete(id: cid, path: asked.path, forget: false)
        cam.refuseDelete = [asked.path]
        let all = cam.files
        cam.files = all.filter { $0.path != asked.path }
        _ = await sync.syncPass()                     // missing once (a short listing)
        cam.files = all
        _ = await sync.syncPass()                     // back: still refused
        cam.files = all.filter { $0.path != asked.path }
        _ = await sync.syncPass()                     // missing once again — not two in a row
        XCTAssertFalse(server.doneIDs.contains(cid))
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

    func testQueuedDeletesReachTheServerAwayFromTheCamera() async {
        onCamera = false
        let asked = cam.files[2]
        sync.defaults.setValue([asked.path], forKey: DashcamSync.cameraDeletesKey)   // an older build's list
        await sync.pushLocalDeletes()
        XCTAssertEqual(server.marked.map(\.id), [id(asked)])
        XCTAssertEqual(sync.pendingCameraDeletes, [asked.path: false], "kept until the camera has done it")
    }

    func testADeleteAskedAwayWaitsOnTheServerAndThePhone() async {
        onCamera = false
        let asked = cam.files[1]
        let now = await sync.deleteFromCamera(asked.path, clipID: id(asked), forget: true)
        XCTAssertEqual(now, .pending)
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

    // MARK: Locked clips

    private func serverClip(_ f: DashcamFile, tags: [String] = [], phone: String = "none", uploaded: Bool = false,
                            onCamera: Bool = true, drive: Bool = false) -> DashcamServerClip {
        var json: [String: Any] = ["id": id(f), "camera_id": "CAM", "path": f.path, "kind": f.kind.rawValue,
                                   "lens": f.lens.rawValue, "start": f.start.dashcamISO, "duration_s": f.durationS,
                                   "size": f.size, "phone": ["state": phone], "on_camera": onCamera, "tags": tags,
                                   "locked": !tags.isEmpty, "uploaded": uploaded,
                                   "upload": ["state": uploaded ? "done" : "none"]]
        if drive { json["destinations"] = ["d_drive": ["state": "done", "file_id": "F1"]] }
        return DashcamServerClip(json: json)!
    }

    /// His accident clip: tagged, so nothing deletes it — not the phone, the cloud, the card, nor everywhere.
    func testALockedClipIsNeverDeletedFromAnywhere() async throws {
        let f = eventClip
        let url = sync.storage.localURL(camera: "CAM", file: f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        for clip in [serverClip(f, tags: ["accident"]), serverClip(f)] {
            if clip.tags.isEmpty { DashcamTagged.mark(clip.id, defaults: sync.defaults) }    // tagged on this phone only
            let (done, failed) = await DashcamClipActions.delete(clip, [.phone, .cloud, .camera], sync: sync)
            XCTAssertEqual(done, [])
            XCTAssertEqual(failed, [DashcamLock.refusal])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the phone copy stays")
        XCTAssertFalse(DashcamTombstones.contains(id(f), defaults: sync.defaults))
        XCTAssertTrue(server.marked.isEmpty, "nothing queued for the card")
        let now = await sync.deleteFromCamera(f.path, clipID: id(f))
        XCTAssertEqual(now, .locked)
        XCTAssertTrue(server.marked.isEmpty)
        XCTAssertTrue(sync.pendingCameraDeletes.isEmpty)
    }

    /// The card's clean-up never takes a locked clip's file — uploaded or on the phone, tagged on the server or here.
    func testTheCardSweepAndDownloadsLeaveLockedClipsOnTheCard() async {
        let uploaded = cam.files[0], here = eventClip
        server.uploadedIDs = [id(uploaded)]
        server.lockedIDs = [id(uploaded)]                       // the server's word
        DashcamTagged.mark(id(here), defaults: sync.defaults)   // this phone's record
        fetcher.failAfter = 0
        _ = await sync.syncPass()                               // sizes known: a download would now leave the card
        fetcher.failAfter = nil
        let report = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == here.name }, "a locked clip still comes down")
        XCTAssertFalse(cam.deleted.contains(here.path), "but stays on the card after its download")
        XCTAssertFalse(cam.deleted.contains(uploaded.path), "and the sweep skips it though the cloud has it")
        XCTAssertFalse(report.cardDeleted.contains(uploaded.path))
        XCTAssertTrue(sync.isLocked(path: uploaded.path) && sync.isLocked(path: here.path))
    }

    /// A delete asked for before the clip was tagged never runs, and doesn't keep the clip off the phone either.
    func testABacklogDeleteOfALockedClipIsNotRun() async {
        let asked = eventClip
        server.backlog[id(asked)] = DashcamCardDelete(id: id(asked), path: asked.path, forget: true)
        sync.defaults.setValue([asked.path: true], forKey: DashcamSync.cardDeletesKey)
        server.lockedIDs = [id(asked)]                          // tagged on the server since; this phone doesn't know yet
        server.listed = [serverClip(asked, tags: ["accident"])]
        _ = await sync.syncPass()
        _ = await sync.syncPass()
        XCTAssertFalse(cam.deleted.contains(asked.path))
        XCTAssertFalse(server.doneIDs.contains(id(asked)))
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == asked.name }, "kept out of nothing: it comes down")
        XCTAssertNil(sync.pendingCameraDeletes[asked.path], "off this phone's list")
    }

    /// A locked clip already in the cloud whose phone copy went comes back from the card — and isn't sent up again.
    func testALockedClipComesBackFromTheCardWithoutUploadingAgain() async {
        let f = cam.files[0]                                    // normal footage: off by default, and in the cloud
        server.uploadedIDs = [id(f)]
        server.lockedIDs = [id(f)]
        DashcamTombstones.add(id(f), defaults: sync.defaults)   // deleted here before he tagged it
        _ = await sync.syncPass()
        _ = await sync.syncPass()
        XCTAssertTrue(sync.storage.exists(camera: "CAM", file: f))
        XCTAssertFalse(DashcamTombstones.contains(id(f), defaults: sync.defaults), "the lock wins")
        let queued = await sync.uploader.jobs.map(\.clipID)
        XCTAssertFalse(queued.contains(id(f)), "the cloud has it: nothing goes up again")
        XCTAssertEqual(server.phone[id(f)], "local")
        XCTAssertFalse(cam.deleted.contains(f.path))
    }

    /// Locked copies stay on the phone for good, so they never fill "Phone space" and hold back normal footage.
    func testLockedCopiesDoNotCountAgainstPhoneSpace() async throws {
        var rules = DashcamRules(); rules.normal = .all; rules.phoneCapGB = 1
        server.rules = rules
        let locked = cam.files[0]
        server.lockedIDs = [id(locked)]
        let url = sync.storage.localURL(camera: "CAM", file: locked)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)                 // 1 GB on paper (sparse): the whole cap
        try handle.close()
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == "rear_0.mp4" }, "normal footage still comes down")
        XCTAssertLessThan(sync.phoneBytes ?? .max, 1 << 20)
        XCTAssertFalse(cam.deleted.contains(locked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The Oct 21 clip: tagged, uploaded, its phone copy cleared, gone from the card. It comes back from the cloud as
    /// the MP4 the cloud keeps, counts as the phone copy, is marked on the phone and never queued for upload.
    func testALockedClipWithNoPhoneCopyComesBackFromTheCloud() async throws {
        let f = DashcamFile(path: "/mnt/card/video_back/2026-10-21_16_17_37_b.ts", kind: .normal, lens: .rear,
                            start: Date(timeIntervalSince1970: 1_792_000_000), durationS: 60, size: 5_000)
        let clip = serverClip(f, tags: ["accident"], phone: "deleted", uploaded: true, onCamera: false, drive: true)
        server.listed = [clip, serverClip(file(.normal, .front, at: 0))]
        var asked: [String] = []
        sync.restoreSources = { c in asked.append(c.id); return [URLRequest(url: URL(string: "https://drive.test/\(c.id)")!)] }
        sync.restoreFetch = { _, dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("download.mp4")
            try Data(count: 3_000).write(to: out)
            return out
        }
        let back = await sync.restoreLocked()
        XCTAssertEqual(back, [clip.id])
        XCTAssertEqual(asked, [clip.id], "only the locked clip")
        let local = sync.storage.localURL(camera: "CAM", file: f)
        XCTAssertEqual(local.lastPathComponent, "2026-10-21_16_17_37_b.mp4")
        XCTAssertTrue(sync.storage.exists(camera: "CAM", file: f), "the smaller MP4 counts as the phone copy")
        XCTAssertEqual(server.phone[clip.id], "local")
        let queued = await sync.uploader.jobs.map(\.clipID)
        XCTAssertTrue(queued.isEmpty, "never uploaded again")
        XCTAssertTrue(DashcamTagged.contains(clip.id, defaults: sync.defaults))
        // Already there: the next check fetches nothing.
        let again = await sync.restoreLocked()
        XCTAssertEqual(again, [])
        XCTAssertEqual(asked.count, 1)
        // Its copy never counts against the phone-space cap.
        XCTAssertEqual(sync.storage.normalBytes(camera: "CAM",
                                                excluding: Set(sync.defaults.stringArray(forKey: DashcamSync.lockedCopiesKey) ?? [])), 0)
        // At most every ten minutes on its own.
        sync.restoreLockedSoon()
        await Task.yield()
        XCTAssertEqual(asked.count, 1)
    }

    /// Cloud backup paused, mobile data "Nothing": a locked clip still goes up — and first.
    func testLockedClipsUploadWhateverTheRules() async throws {
        let upload = FakeUploadServer()
        sync.uploadServer = upload
        sync.charging = { false }
        sync.rules.upload = false
        sync.rules.uploadData = .never
        for (name, kind) in [("e", DashcamClipKind.event), ("n", .normal)] {
            let url = root.appendingPathComponent("\(name).mp4")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(count: 8).write(to: url)
            await sync.uploader.enqueue(clipID: name, local: url, size: 8, kind: kind)
        }
        DashcamTagged.mark("n", defaults: sync.defaults)
        await sync.uploadOnce()
        XCTAssertEqual(upload.completed, ["u_n"], "only the locked clip, though backup is paused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("n.mp4").path), "and it stays on the phone")
    }

    // MARK: Locked clips: review fixes

    /// He deleted a clip everywhere away from the car, then tagged it on the web: at the next connection the server
    /// refuses the queued delete as locked, and the card keeps the file (it may be the only copy).
    func testAQueuedDeleteTheServerNowCallsLockedNeverRuns() async {
        onCamera = false
        let f = eventClip
        let asked = await sync.deleteFromCamera(f.path, clipID: id(f), forget: true)
        XCTAssertEqual(asked, .pending)
        XCTAssertEqual(sync.pendingCameraDeletes[f.path], true)
        server.backlog[id(f)] = nil                             // the server drops the entry when the clip is tagged
        server.lockedIDs = [id(f)]
        onCamera = true
        _ = await sync.syncPass()
        XCTAssertFalse(cam.deleted.contains(f.path))
        XCTAssertNil(sync.pendingCameraDeletes[f.path], "off this phone's queue")
        XCTAssertTrue(sync.isLocked(path: f.path))
        XCTAssertTrue(DashcamTagged.contains(id(f), defaults: sync.defaults), "remembered across launches")
    }

    /// On the camera's Wi‑Fi with a clip object older than its tag: the server's answer refuses it before the camera
    /// is asked.
    func testADeleteTheServerCallsLockedIsRefusedOnTheCameraWiFi() async {
        let f = cam.files[1]
        server.lockedIDs = [id(f)]
        let result = await sync.deleteFromCamera(f.path, clipID: id(f))
        XCTAssertEqual(result, .locked)
        XCTAssertFalse(cam.deleted.contains(f.path))
        XCTAssertTrue(sync.pendingCameraDeletes.isEmpty)
    }

    /// With the server answering, only what it queued (or lists) goes; with it down, this phone's queue runs as before.
    func testOnlyDeletesTheServerQueuedRunUnlessItIsDown() async {
        let f = cam.files[1]
        sync.defaults.setValue([f.path: false], forKey: DashcamSync.cardDeletesKey)
        server.unmarked = [id(f)]
        _ = await sync.syncPass()
        XCTAssertFalse(cam.deleted.contains(f.path), "the server answered and didn't queue it")
        server.unmarked = []
        server.unreachable = true
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(f.path), "server down: the phone's own queue")
    }

    /// He tags a clip while a pass pulls it: its card file stays.
    func testAClipTaggedWhileItComesDownStaysOnTheCard() async {
        fetcher.failAfter = 0
        _ = await sync.syncPass()                               // sizes known: a download would now leave the card
        fetcher.failAfter = nil
        let defaults = sync.defaults, eid = eventID, name = eventClip.name, fetcher = self.fetcher!
        fetcher.onFetch = { if fetcher.fetched.last?.lastPathComponent == name { DashcamTagged.mark(eid, defaults: defaults) } }
        _ = await sync.syncPass()
        XCTAssertTrue(fetcher.fetched.contains { $0.lastPathComponent == name })
        XCTAssertFalse(cam.deleted.contains(eventClip.path))
    }

    /// Tagged mid-sweep: the sweep asks again before each file and leaves it.
    func testAClipTaggedDuringTheSweepIsLeftOnTheCard() async {
        let a = cam.files[0], b = cam.files[3]
        server.uploadedIDs = [id(a), id(b)]
        _ = await sync.syncPass()                               // sizes known
        let defaults = sync.defaults, bid = id(b), aPath = a.path
        cam.onDelete = { f in if f.path == aPath { DashcamTagged.mark(bid, defaults: defaults) } }
        _ = await sync.syncPass()
        XCTAssertTrue(cam.deleted.contains(a.path))
        XCTAssertFalse(cam.deleted.contains(b.path))
    }

    /// The clip object is older than the server's word this run (locked since): a phone delete refuses it.
    func testAPhoneDeleteRefusesAClipTheServerCalledLockedThisRun() async {
        let f = cam.files[0]
        server.lockedIDs = [id(f)]
        _ = await sync.syncPass()                               // the inventory says locked; it comes down to the phone
        let url = sync.storage.localURL(camera: "CAM", file: f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let (done, failed) = await DashcamClipActions.delete(serverClip(f, phone: "local"), [.phone], sync: sync)
        XCTAssertEqual(done, [])
        XCTAssertEqual(failed, [DashcamLock.refusal])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func putLocal(_ f: DashcamFile) throws -> URL {
        let url = sync.storage.localURL(camera: "CAM", file: f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        return url
    }

    /// Nothing here says it's locked, but the server does when asked: the phone's copy stays.
    func testAPhoneDeleteAsksTheServerFirst() async throws {
        let f = eventClip
        let url = try putLocal(f)
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["clip": ["id": id(f), "path": f.path, "tags": ["accident"], "locked": true]])
        let (done, failed) = await DashcamClipActions.delete(serverClip(f, phone: "local"), [.phone], sync: sync,
                                                             api: DashcamAPI(api: api))
        XCTAssertEqual(done, [])
        XCTAssertEqual(failed, [DashcamLock.refusal])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(DashcamTombstones.contains(id(f), defaults: sync.defaults))
        XCTAssertTrue(DashcamTagged.contains(id(f), defaults: sync.defaults))
    }

    /// A cloud delete that fails keeps the phone's copy (it may be the only one left).
    func testAFailedCloudDeleteKeepsThePhoneCopy() async throws {
        let f = eventClip
        let url = try putLocal(f)
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(MockTransport.Reply(status: 502, body: Data("down".utf8)))
        let (done, failed) = await DashcamClipActions.delete(serverClip(f, phone: "local", uploaded: true), [.phone, .cloud],
                                                             sync: sync, api: DashcamAPI(api: api))
        XCTAssertEqual(done, [])
        XCTAssertEqual(failed.count, 2)
        XCTAssertTrue(failed[1].hasPrefix("phone: kept"), failed[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(DashcamTombstones.contains(id(f), defaults: sync.defaults))
    }

    /// The server refuses the card delete as locked (tagged on the web): it's an error, never "pending", and the
    /// clip isn't forgotten.
    func testACameraDeleteTheServerRefusesIsAnErrorNotPending() async {
        onCamera = false
        let f = cam.files[1]
        server.lockedIDs = [id(f)]
        let (done, failed) = await DashcamClipActions.delete(serverClip(f), [.camera], sync: sync)
        XCTAssertEqual(done, [])
        XCTAssertEqual(failed, ["dashcam: " + DashcamLock.refusal])
    }

    /// Tags taken off on the web: the server's whole list of locked clips unlocks it here too — not one tagged here
    /// a moment ago — and a card delete then goes through instead of silently never happening.
    func testAClipUntaggedOnTheServerUnlocksHere() async {
        let f = cam.files[1], g = cam.files[2]
        DashcamTagged.mark(id(f), defaults: sync.defaults, now: sync.now().addingTimeInterval(-3600))   // an hour ago
        DashcamTagged.mark(id(g), defaults: sync.defaults, now: sync.now().addingTimeInterval(-60))     // a minute ago
        XCTAssertTrue(sync.isLocked(path: f.path))
        server.listed = []                                      // no tag lists either any more
        let onCard = await sync.lockedOnCardCount([f, g])
        XCTAssertEqual(onCard, 1, "only the one tagged a minute ago (the list may predate the tap)")
        XCTAssertFalse(sync.isLocked(path: f.path))
        XCTAssertTrue(sync.isLocked(path: g.path))
        let result = await sync.deleteFromCamera(f.path, clipID: id(f))
        XCTAssertEqual(result, .deleted)
        XCTAssertTrue(cam.deleted.contains(f.path))
    }

    private func cloudClip(_ name: String, tags: [String], uploaded: Bool = true, size: Int64 = 5_000) -> (DashcamFile, DashcamServerClip) {
        let f = DashcamFile(path: "/mnt/card/video_back/\(name).ts", kind: .normal, lens: .rear,
                            start: Date(timeIntervalSince1970: 1_792_000_000), durationS: 60, size: size)
        return (f, serverClip(f, tags: tags, phone: "deleted", uploaded: uploaded, onCamera: false, drive: true))
    }

    private func fetchWrites(_ bytes: Data, into asked: @escaping (URLRequest) -> Void = { _ in }) {
        sync.restoreFetch = { request, dir in
            asked(request)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("download.mp4")
            try bytes.write(to: out)
            return out
        }
    }

    /// Only clips the server says are uploaded come back; over mobile data only accidents and near misses, the rest
    /// on Wi‑Fi.
    func testRestoreTakesOnlyUploadedClipsAndOnMobileDataOnlyAccidents() async {
        let (_, accident) = cloudClip("a_b", tags: ["accident"])
        let (_, scenic) = cloudClip("s_b", tags: ["scenic"])
        let (_, uploading) = cloudClip("u_b", tags: ["accident"], uploaded: false)
        server.listed = [accident, scenic, uploading]
        sync.restoreSources = { c in [URLRequest(url: URL(string: "https://drive.test/\(c.id)")!)] }
        fetchWrites(Data(count: 3_000))
        onCamera = true                                         // the internet goes over LTE here
        let onLTE = await sync.restoreLocked()
        XCTAssertEqual(onLTE, [accident.id])
        onCamera = false                                        // Wi‑Fi
        let onWiFi = await sync.restoreLocked()
        XCTAssertEqual(onWiFi, [scenic.id], "the scenic one waited for Wi‑Fi; the one still uploading never comes")
    }

    /// A restore never takes the phone below 5 GB free.
    func testRestoreKeepsFiveGBFree() async {
        let (_, clip) = cloudClip("a_b", tags: ["accident"], size: 2_000)
        server.listed = [clip]
        onCamera = false
        var asked = 0
        sync.restoreSources = { _ in [URLRequest(url: URL(string: "https://drive.test/x")!)] }
        fetchWrites(Data(count: 100)) { _ in asked += 1 }
        sync.freeSpace = { DashcamSync.restoreFreeFloor + 1_000 }
        let none = await sync.restoreLocked()
        XCTAssertEqual(none, [])
        XCTAssertEqual(asked, 0)
        sync.freeSpace = { DashcamSync.restoreFreeFloor + 1_000_000 }
        let back = await sync.restoreLocked()
        XCTAssertEqual(back, [clip.id])
    }

    /// A failed restore backs off (kept across launches), tries one source an attempt — the Drive file, then the
    /// server's stream next time — and holds the keepalive while it downloads.
    func testAFailedRestoreBacksOffAndTriesTheNextSourceNextTime() async {
        let sync = self.sync!
        let (_, clip) = cloudClip("a_b", tags: ["accident"])
        server.listed = [clip]
        onCamera = false
        var clock = Date(timeIntervalSince1970: 1_790_010_000)
        sync.now = { clock }
        sync.restoreSources = { _ in [URLRequest(url: URL(string: "https://drive.test/f")!),
                                      URLRequest(url: URL(string: "https://jarvis.test/stream")!)] }
        var asked: [String] = []
        var heldKeepalive = false
        sync.restoreFetch = { request, dir in
            asked.append(request.url!.host!)
            heldKeepalive = sync.holdsKeepalive
            if request.url!.host == "drive.test" { throw URLError(.timedOut) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("download.mp4")
            try Data(count: 3_000).write(to: out)
            return out
        }
        let first = await sync.restoreLocked()
        XCTAssertEqual(first, [])
        XCTAssertEqual(asked, ["drive.test"], "no second full download in the same attempt")
        XCTAssertTrue(heldKeepalive)
        XCTAssertFalse(sync.holdsKeepalive)
        XCTAssertNotNil(sync.defaults.dictionary(forKey: DashcamSync.restoreBackoffKey)?[clip.id], "kept across launches")
        _ = await sync.restoreLocked()
        XCTAssertEqual(asked.count, 1, "waiting out its back-off")
        clock = clock.addingTimeInterval(DashcamSync.restoreBackoffBase + 1)
        let second = await sync.restoreLocked()
        XCTAssertEqual(second, [clip.id])
        XCTAssertEqual(asked, ["drive.test", "jarvis.test"])
        XCTAssertNil(sync.defaults.dictionary(forKey: DashcamSync.restoreBackoffKey)?[clip.id])
        XCTAssertEqual(DashcamSync.restoreDelay(attempts: 1), 600)
        XCTAssertEqual(DashcamSync.restoreDelay(attempts: 2), 1200)
        XCTAssertEqual(DashcamSync.restoreDelay(attempts: 30), 86400)
    }

    /// The cloud handed back the camera's own `.ts`: it lands under the camera's name, and is still never sent up
    /// again as a new clip, whatever upload state the server reports later.
    func testARestoredCopyIsNeverQueuedForUploadAgain() async {
        let (f, clip) = cloudClip("2026-10-21_16_17_37_b", tags: ["accident"])
        server.listed = [clip]
        onCamera = false
        sync.restoreSources = { _ in [URLRequest(url: URL(string: "https://jarvis.test/stream")!)] }
        var ts = Data(count: 376)
        ts[0] = 0x47; ts[188] = 0x47
        fetchWrites(ts)
        let back = await sync.restoreLocked()
        XCTAssertEqual(back, [clip.id])
        XCTAssertEqual(sync.storage.localURL(camera: "CAM", file: f).lastPathComponent, "2026-10-21_16_17_37_b.ts", "sniffed as TS")
        var later = serverClip(f, tags: ["accident"], phone: "local", uploaded: false, onCamera: false)
        later.uploadState = "none"
        server.listed = [later]
        await sync.cleanUpUploaded()
        let queued = await sync.uploader.contains(clip.id)
        XCTAssertFalse(queued)
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

    /// Tagged clips go first and whatever the rules say; the rest wait their turn as before.
    func testLockedClipsGoFirstAndPastTheRules() async throws {
        let uploader = DashcamUploader(file: try tempDir().appendingPathComponent("q.json"), tombstones: suite())
        await uploader.enqueue(clipID: "e", local: try tempFile(4), size: 4, kind: .event)
        await uploader.enqueue(clipID: "n", local: try tempFile(4), size: 4, kind: .normal)
        let server = FakeUploadServer()
        let held = await uploader.run(server: server, cellular: true, allow: { _ in false }, locked: ["n"])
        XCTAssertEqual(held, ["n"], "uploads off or held: the locked one still goes")
        await uploader.enqueue(clipID: "n2", local: try tempFile(4), size: 4, kind: .normal)
        let both = await uploader.run(server: server, cellular: false, locked: ["n2"])
        XCTAssertEqual(both, ["n2", "e"], "locked first, ahead of the event")
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

/// The camera's Wi‑Fi joined with Jarvis in the background: its name can come after the path
/// update, so the watchdog keeps looking — it used to only with the app open (2026-11-05).
@MainActor
final class DashcamWiFiBackgroundTests: XCTestCase {
    func testTheBackgroundKeepsLookingWithTheCarOrJustAfterAWiFiChange() {
        XCTAssertTrue(DashcamWiFi.looksInBackground(inCar: true, sinceWiFiChange: nil))
        XCTAssertTrue(DashcamWiFi.looksInBackground(inCar: false, sinceWiFiChange: 30))
        XCTAssertFalse(DashcamWiFi.looksInBackground(inCar: false, sinceWiFiChange: DashcamWiFi.settleWindow + 1),
                       "at home, long after: the pocket stays quiet")
        XCTAssertFalse(DashcamWiFi.looksInBackground(inCar: false, sinceWiFiChange: nil))
    }
}
