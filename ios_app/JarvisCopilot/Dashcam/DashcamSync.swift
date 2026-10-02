import CoreMotion
import CryptoKit
import Foundation
import Network

/// The server calls a sync pass makes (`DashcamAPI`, or a fake in tests).
protocol DashcamSyncServer: Sendable {
    func upsertCamera(_ info: DashcamCameraInfo, ssid: String) async throws
    func inventory(cameraID: String, files: [DashcamFile]) async throws -> [String: DashcamInventoryRow]
    func putFixes(clipID: String, fixes: [DashcamFix]) async throws
    func putThumb(clipID: String, jpeg: Data) async throws
    func setPhone(clipID: String, state: String, error: String?) async throws
    func state() async throws -> DashcamServerState
    func clips(_ filter: DashcamAPI.ClipFilter, cursor: String?, limit: Int) async throws -> (clips: [DashcamServerClip], next: String?)
}

extension DashcamAPI: DashcamSyncServer {}

protocol DashcamFetcher: Sendable {
    func download(_ url: URL, to dest: URL, key: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

extension DashcamDownloader: DashcamFetcher {}

enum DashcamIDs {
    /// The server's clip id: `c_` + the first 20 hex digits of SHA-1("<camera>:<path>").
    static func clipID(cameraID: String, path: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(cameraID):\(path)".utf8))
        return "c_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }
}

/// "Has the car been still for a few minutes?" — from the phone's motion coprocessor. Without
/// motion access the answer is "no", which only ever delays a sync, never interrupts recording.
enum DashcamMotion {
    static func isParked(window: TimeInterval = 180) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return false }
        let manager = CMMotionActivityManager()
        let now = Date()
        return await withCheckedContinuation { cont in
            manager.queryActivityStarting(from: now.addingTimeInterval(-window), to: now, to: .main) { activities, _ in
                let driving = (activities ?? []).contains { $0.automotive && $0.confidence != .low }
                cont.resume(returning: !driving)
            }
        }
    }
}

/// Runs the dashcam: a sync pass every minute while the phone is on the camera's Wi‑Fi, and
/// uploads whenever the server is reachable.
@MainActor
final class DashcamSync: ObservableObject {
    static let shared = DashcamSync()

    enum Phase: Equatable {
        case notSetUp
        case away
        case syncing(String)
        case waitingForPark
        case idle
        case error(String)

        var label: String {
            switch self {
            case .notSetUp: return "Not set up"
            case .away: return "Away"
            case .syncing(let step): return step
            case .waitingForPark: return "Waiting until parked"
            case .idle: return "Up to date"
            case .error(let m): return m
            }
        }
    }

    struct Report: Equatable {
        var listed = 0
        var gps = 0
        var thumbs = 0
        var downloaded: [String] = []
        var skippedUnstable = 0
        var usedPlayback = false
    }

    @Published private(set) var phase: Phase = .notSetUp
    @Published private(set) var info: DashcamCameraInfo?
    @Published private(set) var sd: DashcamSDInfo?
    @Published private(set) var recording: Bool?
    @Published private(set) var cameraFiles: [DashcamFile] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var downloading: (name: String, done: Int64, total: Int64)?
    @Published private(set) var uploading: (clipID: String, done: Int64, total: Int64)?
    @Published private(set) var queuedDownloads = 0
    @Published private(set) var pendingUploads = 0
    @Published var rules = DashcamRules()

    // Dependencies (swapped in tests).
    var setupProvider: () -> DashcamSetup? = { DashcamSetupStore.load() }
    var cameraFactory: (DashcamSetup) -> DashcamCamera? = { setup in
        let base = DashcamSetupStore.debugHost().flatMap { URL(string: "http://" + $0) } ?? setup.base()
        return base.flatMap { DashcamDetect.camera(family: setup.family, base: $0) }
    }
    var server: DashcamSyncServer = DashcamAPI()
    var uploadServer: DashcamUploadServer = DashcamAPI()
    var fetcher: DashcamFetcher = DashcamDownloader.shared
    var uploader: DashcamUploader = .shared
    var storage: DashcamStorage = .standard
    var parked: () async -> Bool = { await DashcamMotion.isParked() }
    var onCameraProvider: () -> Bool = { DashcamWiFi.shared.onCamera }
    var now: () -> Date = { Date() }
    var tzOffset: () -> Int = { TimeZone.current.secondsFromGMT() }

    /// Paths someone asked for (`dashcam_fetch_range`), pulled even when the rules say no.
    private(set) var forced = Set<String>()
    /// Sizes from the previous listing: a clip still being written grows between listings.
    private var lastSizes: [String: Int64] = [:]
    private var cameraLoop: Task<Void, Never>?
    private var uploadLoop: Task<Void, Never>?
    private var passRunning = false
    private let pathMonitor = NWPathMonitor()
    private var internetPath: NWPath?

    init() {}

    // MARK: Lifecycle

    /// Called once at launch (AppServices).
    func start() {
        guard setupProvider() != nil else { phase = .notSetUp; return }
        phase = .away
        DashcamWiFi.shared.onChange = { [weak self] on in self?.cameraChanged(on) }
        DashcamWiFi.shared.start()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.internetPath = path; self?.kickUploads() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "jc.dashcam.path"))
        Task { await refreshRules(); await refreshCounts() }
        kickUploads()
    }

    func cameraChanged(_ on: Bool) {
        cameraLoop?.cancel()
        guard on else { phase = setupProvider() == nil ? .notSetUp : .away; return }
        cameraLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.onCameraProvider() else { return }
                _ = await self.syncPass()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Run a pass now (Sync now, `dashcam_sync`).
    @discardableResult
    func syncNow() async -> Report {
        guard onCameraProvider() else { phase = .away; return Report() }
        return await syncPass()
    }

    // MARK: One pass while on the camera's Wi‑Fi

    @discardableResult
    func syncPass() async -> Report {
        var report = Report()
        guard !passRunning else { return report }
        guard var setup = setupProvider(), let cam = cameraFactory(setup) else { phase = .notSetUp; return report }
        passRunning = true
        defer { passRunning = false }
        let tz = tzOffset()

        phase = .syncing("Connecting to the dashcam")
        let info: DashcamCameraInfo
        do { info = try await cam.info() } catch {
            phase = onCameraProvider() ? .error(error.localizedDescription) : .away
            return report
        }
        self.info = info
        try? await server.upsertCamera(info, ssid: setup.ssid)
        try? await cam.setTime(now(), timeZone: TimeZone(secondsFromGMT: tz) ?? .current)
        let wasRecording = try? await cam.isRecording()
        recording = wasRecording
        sd = try? await cam.sdInfo()

        // Listing. Some firmware only lists in playback mode, which can pause recording:
        // that is only ever done while the car is parked, and recording is restored after.
        var files: [DashcamFile] = []
        var usedPlayback = false
        do {
            if setup.listingNeedsPlayback {
                guard await parked() else { phase = .waitingForPark; return report }
                try await cam.playback(true)
                usedPlayback = true
            }
            phase = .syncing("Reading the card")
            do {
                files = try await cam.files(tzOffset: tz)
            } catch DashcamError.camera where !usedPlayback && setup.family == .viidure {
                setup.listingNeedsPlayback = true
                DashcamSetupStore.save(setup)
                guard await parked() else { phase = .waitingForPark; return report }
                try await cam.playback(true)
                usedPlayback = true
                files = try await cam.files(tzOffset: tz)
            }
            report.usedPlayback = usedPlayback
            report = await work(on: files, camera: cam, setup: setup, cameraID: info.id, tz: tz,
                                recording: wasRecording ?? true, report: report)
        } catch {
            phase = onCameraProvider() ? .error(error.localizedDescription) : .away
        }
        if usedPlayback {
            try? await cam.playback(false)
            if wasRecording == true, (try? await cam.isRecording()) == false {
                try? await cam.setRecording(true)
            }
            recording = try? await cam.isRecording()
        }
        if case .syncing = phase { phase = .idle }
        lastSync = now()
        await refreshCounts()
        kickUploads()
        return report
    }

    private func work(on files: [DashcamFile], camera cam: DashcamCamera, setup: DashcamSetup, cameraID: String,
                      tz: Int, recording: Bool, report start: Report) async -> Report {
        var report = start
        report.listed = files.count
        cameraFiles = files.sorted { $0.start > $1.start }
        let rows = (try? await server.inventory(cameraID: cameraID, files: files)) ?? [:]
        func clipID(_ f: DashcamFile) -> String { rows[f.path]?.id ?? DashcamIDs.clipID(cameraID: cameraID, path: f.path) }

        // A clip may still be growing while the camera records: the newest normal/parking clip of
        // each lens (the folders it records into), or any clip whose expected end is under a
        // minute ago. It becomes safe once its size holds still between two listings.
        var newest: [String: DashcamFile] = [:]
        for f in files where f.kind == .normal || f.kind == .parking {
            let key = "\(f.lens.rawValue)/\(f.folder)"
            if let cur = newest[key], cur.start >= f.start { continue }
            newest[key] = f
        }
        let nowT = now()
        func stable(_ f: DashcamFile) -> Bool {
            if lastSizes[f.path] == f.size { return true }
            guard f.isVideo, recording else { return true }
            if newest["\(f.lens.rawValue)/\(f.folder)"]?.path == f.path { return false }
            return f.start.addingTimeInterval(max(f.durationS, 60) + 60) < nowT
        }
        defer { lastSizes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) }) }

        // GPS + speed for every finished clip (two small range reads each).
        phase = .syncing("Reading GPS")
        for f in files where f.isVideo && stable(f) && rows[f.path]?.hasGPS != true {
            guard onCameraProvider(), !Task.isCancelled else { return report }
            if let fixes = try? await cam.gps(f, tzOffset: tz), !fixes.isEmpty {
                if (try? await server.putFixes(clipID: clipID(f), fixes: fixes)) != nil { report.gps += 1 }
            }
        }

        // Thumbnails for the library.
        phase = .syncing("Fetching thumbnails")
        for f in files where stable(f) && rows[f.path] != nil && rows[f.path]?.hasThumb != true {
            guard onCameraProvider(), !Task.isCancelled, report.thumbs < 60 else { break }
            guard let data = await cam.thumbnail(f) else { continue }
            if (try? await server.putThumb(clipID: clipID(f), jpeg: data)) != nil { report.thumbs += 1 }
        }

        // Downloads by rule (events and photos first).
        let isParked = await parked()
        let wanted = DashcamRules.order(files.filter { f in
            guard !storage.exists(camera: cameraID, file: f), rows[f.path]?.uploaded != true else { return false }
            guard stable(f) else { report.skippedUnstable += 1; return false }
            return forced.contains(f.path)
                || rules.wants(f, parked: isParked, normalBytesOnPhone: storage.normalBytes(camera: cameraID))
        })
        queuedDownloads = wanted.count
        for f in wanted {
            guard onCameraProvider(), !Task.isCancelled else { break }
            if f.kind == .normal, !forced.contains(f.path),
               !rules.wants(f, parked: isParked, normalBytesOnPhone: storage.normalBytes(camera: cameraID)) { continue }
            let id = clipID(f)
            let dest = storage.localURL(camera: cameraID, file: f)
            phase = .syncing("Downloading \(f.name)")
            try? await server.setPhone(clipID: id, state: "downloading", error: nil)
            do {
                try await fetcher.download(cam.fileURL(f), to: dest, key: id) { done, total in
                    Task { @MainActor in self.downloading = (f.name, done, total > 0 ? total : f.size) }
                }
                downloading = nil
                forced.remove(f.path)
                report.downloaded.append(f.path)
                try? await server.setPhone(clipID: id, state: "local", error: nil)
                await uploader.enqueue(clipID: id, local: dest, size: f.size, kind: f.kind)
                queuedDownloads = max(0, queuedDownloads - 1)
            } catch {
                downloading = nil
                try? await server.setPhone(clipID: id, state: "failed", error: error.localizedDescription)
                if !onCameraProvider() { break }
            }
        }
        queuedDownloads = 0
        return report
    }

    // MARK: Uploads

    /// Starts the upload loop if there is anything to send and nothing is running.
    func kickUploads() {
        guard uploadLoop == nil else { return }
        uploadLoop = Task { [weak self] in
            defer { Task { @MainActor in self?.uploadLoop = nil } }
            while !Task.isCancelled {
                guard let self else { return }
                let pending = await self.uploader.pendingCount
                self.pendingUploads = pending
                if pending == 0 { await self.cleanUpUploaded(); return }
                await self.uploadOnce()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func uploadOnce() async {
        let path = internetPath
        let onCam = onCameraProvider()
        // On the camera's Wi‑Fi the internet goes over mobile data; off it, Wi‑Fi unless only cellular is up.
        let cellular = onCam || (path.map { !$0.usesInterfaceType(.wifi) && $0.usesInterfaceType(.cellular) } ?? false)
        if path?.status == .unsatisfied && !onCam { return }
        let done = await uploader.run(server: uploadServer, cellular: cellular) { id, sent, total in
            Task { @MainActor in self.uploading = (id, sent, total) }
        }
        uploading = nil
        pendingUploads = await uploader.pendingCount
        if !done.isEmpty { await cleanUpUploaded() }
    }

    /// Deletes local copies every destination already has (unless "keep on phone").
    func cleanUpUploaded() async {
        guard !rules.keepOnPhone, let setup = setupProvider() else { return }
        let cameraID = info?.id ?? setup.cameraID
        guard let page = try? await server.clips(DashcamAPI.ClipFilter(state: "on_phone"), cursor: nil, limit: 200) else { return }
        for clip in page.clips where clip.uploaded {
            let f = DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start,
                                durationS: clip.durationS, size: clip.size)
            let url = storage.localURL(camera: cameraID, file: f)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            try? await server.setPhone(clipID: clip.id, state: "deleted", error: nil)
        }
    }

    // MARK: Requests from Jarvis / the UI

    /// Pull (and upload) every clip that overlaps `from…to`, rules or not. Returns how many matched
    /// the last listing; they are fetched on this pass if the camera is reachable, else on the next.
    @discardableResult
    func fetch(from: Date, to: Date) async -> Int {
        let matches = cameraFiles.filter { $0.end >= from && $0.start <= to }
        matches.forEach { forced.insert($0.path) }
        if onCameraProvider() { Task { await self.syncPass() } }
        return matches.count
    }

    func pull(_ path: String) {
        forced.insert(path)
        if onCameraProvider() { Task { await self.syncPass() } }
    }

    func refreshRules() async {
        if let state = try? await server.state() { rules = state.rules }
    }

    func refreshCounts() async {
        pendingUploads = await uploader.pendingCount
    }
}
