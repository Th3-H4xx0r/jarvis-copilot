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

/// "Has the car been still for a few minutes?" from the motion coprocessor's live activity.
///
/// The history query alone can't answer it: it returns *changes* only and lags by minutes, so a
/// drive that started a minute ago, or a steady one, came back empty = "parked". Live updates run
/// only while the phone is on the camera's Wi‑Fi (seeded from the last 30 minutes of history), and
/// anything uncertain — no permission, no reading yet, driving in the last 3 minutes — is "no",
/// which only ever delays a sync, never interrupts recording.
@MainActor
final class DashcamMotion {
    static let shared = DashcamMotion()
    private let manager = CMMotionActivityManager()
    private(set) var latest: CMMotionActivity?
    private(set) var lastDriving: Date?
    private var running = false

    static var allowed: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && [.authorized, .notDetermined].contains(CMMotionActivityManager.authorizationStatus())
    }

    func start() {
        guard !running, Self.allowed else { return }
        running = true
        let now = Date()
        manager.queryActivityStarting(from: now.addingTimeInterval(-1800), to: now, to: .main) { [weak self] acts, _ in
            guard let self, let acts else { return }
            if let end = Self.lastDrivingEnd(acts, now: now) { self.lastDriving = max(self.lastDriving ?? .distantPast, end) }
        }
        manager.startActivityUpdates(to: .main) { [weak self] a in
            guard let self, let a else { return }
            self.latest = a
            if a.automotive && a.confidence != .low { self.lastDriving = Date() }
        }
    }

    func stop() {
        guard running else { return }
        manager.stopActivityUpdates()
        running = false
    }

    /// When the last automotive stretch in `acts` (changes, oldest first) ended: the start of the
    /// change after it, or `now` if it is the latest.
    nonisolated static func lastDrivingEnd(_ acts: [CMMotionActivity], now: Date) -> Date? {
        let sorted = acts.sorted { $0.startDate < $1.startDate }
        for (i, a) in sorted.enumerated().reversed() where a.automotive && a.confidence != .low {
            return i + 1 < sorted.count ? sorted[i + 1].startDate : now
        }
        return nil
    }

    func isParked(now: Date = Date()) -> Bool {
        guard Self.allowed else { return false }
        if !running { start() }
        guard let latest, !latest.automotive else { return false }
        if let lastDriving, now.timeIntervalSince(lastDriving) < 180 { return false }
        return (latest.stationary || latest.walking) && latest.confidence != .low
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
    var parked: () async -> Bool = { await DashcamMotion.shared.isParked() }
    var onCameraProvider: () -> Bool = { DashcamWiFi.shared.onCamera }
    var now: () -> Date = { Date() }
    /// The camera clock's zone (set from the phone every pass); DST-aware, so clips recorded
    /// before a daylight-saving change keep their real time.
    var timeZone: () -> TimeZone = { .current }

    /// Paths someone asked for (`dashcam_fetch_range`), pulled even when the rules say no.
    private(set) var forced = Set<String>()
    /// Sizes from the previous listing: a clip still being written grows between listings.
    private var lastSizes: [String: Int64] = [:]
    private var cameraLoop: Task<Void, Never>?
    private var uploadLoop: Task<Void, Never>?
    private var passRunning = false { didSet { passActive = passRunning } }
    /// A pass is running (the Sync button shows it; tapping it then queues the next pass).
    @Published private(set) var passActive = false
    private var statusWatch: Task<Void, Never>?
    private var statusReads = 0
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
        guard on else {
            DashcamMotion.shared.stop()
            phase = setupProvider() == nil ? .notSetUp : .away
            return
        }
        DashcamMotion.shared.start()
        cameraLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.onCameraProvider() else { return }
                if self.autoSync { _ = await self.syncPass() }
                try? await Task.sleep(for: .seconds(Self.autoInterval))
            }
        }
    }

    /// Auto sync (Settings): new clips are found and pulled on their own every `autoInterval` while the
    /// phone is on the camera's Wi‑Fi. Off → only Sync now and clips someone asked for.
    static let autoSyncKey = "jc.dashcam.autoSync"
    static let autoInterval: Double = 20
    @Published var autoSync: Bool = UserDefaults.standard.object(forKey: DashcamSync.autoSyncKey) as? Bool ?? true {
        didSet {
            defaults.set(autoSync, forKey: Self.autoSyncKey)
            if autoSync, onCameraProvider(), !passRunning { Task { await self.syncPass() } }
        }
    }

    /// The controls changed recording by hand.
    func noteRecording(_ on: Bool) { recording = on }

    /// Run a pass now (Sync now, `dashcam_sync`). One already running chose its files before the tap,
    /// so another follows it.
    @discardableResult
    func syncNow() async -> Report {
        guard onCameraProvider() else { phase = .away; return Report() }
        if passRunning { passSoon(); await refreshStatus(); return Report() }
        return await syncPass()
    }

    // MARK: Live status

    /// Recording state and card space, read on their own. A pass only reads them when it starts, and one
    /// read at the wrong moment (a clip split) left "Stopped" showing for a whole pass.
    func refreshStatus() async {
        guard onCameraProvider(), !liveActive, let setup = setupProvider(), let cam = cameraFactory(setup) else { return }
        if let rec = try? await cam.isRecording() { recording = rec }
        statusReads += 1
        if statusReads % 6 == 1, let card = try? await cam.sdInfo() { sd = card }
    }

    /// Polls the status every few seconds while the dashcam page is open.
    func watchStatus(_ on: Bool) {
        statusWatch?.cancel()
        statusWatch = nil
        guard on else { return }
        statusWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: One pass while on the camera's Wi‑Fi

    /// "The camera may be in playback mode": set *before* asking it to enter, cleared only once
    /// it has demonstrably left. Survives crashes and relaunches, so the next pass always gets it
    /// recording again.
    var defaults: UserDefaults = .standard
    static let playbackFlagKey = "jc.dashcam.maybeInPlayback"
    static let fetchRangesKey = "jc.dashcam.fetchRanges"
    private var maybeInPlayback: Bool {
        get { defaults.bool(forKey: Self.playbackFlagKey) }
        set { defaults.set(newValue, forKey: Self.playbackFlagKey) }
    }
    /// Clips that had no GPS block / no thumbnail at this size — not asked for again every pass.
    private var noGPS: [String: Int64] = [:]
    private var noThumb: [String: Int64] = [:]
    private var passes = 0

    /// Leaves playback mode and gets the camera recording again, in a task of its own so a
    /// cancelled sync (Wi‑Fi dropped, Forget) can't skip it. Retries; recording is restored unless
    /// the camera was known to be stopped before.
    private func leavePlayback(_ cam: DashcamCamera, wasRecording: Bool?) async {
        let ok = await Task { () -> Bool in
            var left = false
            for attempt in 0..<3 {
                if (try? await cam.playback(false)) != nil { left = true; break }
                try? await Task.sleep(for: .seconds(1 + Double(attempt)))
            }
            if wasRecording != false {
                for attempt in 0..<3 {
                    if (try? await cam.isRecording()) == true { break }
                    if (try? await cam.setRecording(true)) != nil, (try? await cam.isRecording()) != false { break }
                    try? await Task.sleep(for: .seconds(1 + Double(attempt)))
                }
            }
            return left
        }.value
        if ok { maybeInPlayback = false }
        recording = try? await cam.isRecording()
    }

    @discardableResult
    func syncPass() async -> Report {
        var report = Report()
        guard !liveActive else { return report }        // the live view has the camera
        guard !passRunning else { return report }
        guard var setup = setupProvider(), let cam = cameraFactory(setup) else { phase = .notSetUp; return report }
        passRunning = true
        defer { passRunning = false }
        passes += 1
        let zone = timeZone()

        phase = .syncing("Connecting to the dashcam")
        let info: DashcamCameraInfo
        do { info = try await cam.info() } catch {
            phase = onCameraProvider() ? .error(error.localizedDescription) : .away
            return report
        }
        self.info = info
        let wasRecording = try? await cam.isRecording()
        // A previous pass (or a crash) may have left it in playback mode: get it recording first.
        if maybeInPlayback { await leavePlayback(cam, wasRecording: nil) }
        await refreshRules()
        try? await server.upsertCamera(info, ssid: setup.ssid)
        try? await cam.setTime(now(), timeZone: zone)
        recording = wasRecording
        sd = try? await cam.sdInfo()

        // Listing. Some firmware only lists in playback mode, which can pause recording: that is
        // only ever done while the car is parked, re-checked before every file, and recording is
        // always restored after.
        var files: [DashcamFile] = []
        var usedPlayback = false
        phase = .syncing("Reading the card")
        let retest = setup.listingNeedsPlayback && passes % 10 == 1
        var refused = false
        func list() async -> [DashcamFile] {
            do { return try await cam.files(timeZone: zone) }
            catch DashcamError.camera { refused = true; return [] }
            catch { return [] }
        }
        if !setup.listingNeedsPlayback || retest {
            files = await list()
            if files.isEmpty && refused {
                try? await Task.sleep(for: .seconds(2))     // a session error right after joining is common
                refused = false
                files = await list()
            }
            if !files.isEmpty && setup.listingNeedsPlayback {
                setup.listingNeedsPlayback = false            // lists fine again (firmware update?)
                DashcamSetupStore.save(setup)
                setupStore(setup)
            }
        }
        // Refused outside playback mode (or known to need it): only ever while parked.
        if files.isEmpty, setup.family == .viidure, setup.listingNeedsPlayback || refused {
            guard await parked() else {
                phase = .waitingForPark
                lastSync = now()
                return report
            }
            guard !liveActive else { return report }
            maybeInPlayback = true
            usedPlayback = true
            if (try? await cam.playback(true)) != nil {
                files = (try? await cam.files(timeZone: zone)) ?? []
                if !files.isEmpty && !setup.listingNeedsPlayback {
                    setup.listingNeedsPlayback = true          // learned only from a listing that worked
                    DashcamSetupStore.save(setup)
                    setupStore(setup)
                }
            }
        }
        report.usedPlayback = usedPlayback
        // One entry per path, whatever the firmware's folders do.
        var seen = Set<String>()
        files = files.filter { seen.insert($0.path).inserted }
        if !files.isEmpty {
            report = await work(on: files, camera: cam, cameraID: info.id, zone: zone,
                                recording: wasRecording ?? true, inPlayback: usedPlayback, report: report)
        }
        if usedPlayback { await leavePlayback(cam, wasRecording: wasRecording) }
        if case .syncing = phase { phase = .idle }
        lastSync = now()
        await refreshCounts()
        kickUploads()
        return report
    }

    /// Persists the learned listing mode for the rest of this pass's dependencies (tests).
    var setupStore: (DashcamSetup) -> Void = { _ in }

    private func work(on files: [DashcamFile], camera cam: DashcamCamera, cameraID: String, zone: TimeZone,
                      recording: Bool, inPlayback: Bool, report start: Report) async -> Report {
        var report = start
        report.listed = files.count
        cameraFiles = files.sorted { $0.start > $1.start }
        let rows = (try? await server.inventory(cameraID: cameraID, files: files)) ?? [:]
        func clipID(_ f: DashcamFile) -> String { rows[f.path]?.id ?? DashcamIDs.clipID(cameraID: cameraID, path: f.path) }
        /// Still on the camera's Wi‑Fi, not cancelled — and, in playback mode, still parked.
        func mayContinue() async -> Bool {
            guard onCameraProvider(), !Task.isCancelled, !liveActive else { return false }
            return inPlayback ? await parked() : true
        }

        // A clip may still be growing while the camera records. The newest normal/parking clip of
        // each lens (the folders it records into) counts as finished only once its size held
        // between two listings AND its expected end is clearly past (a pre-allocated file keeps its
        // size; a camera clock that was wrong makes clips look old) — so a finished parking clip
        // still comes down while the camera records. Any other clip needs one of the two.
        var newest: [String: DashcamFile] = [:]
        for f in files where f.kind == .normal || f.kind == .parking {
            let key = "\(f.lens.rawValue)/\(f.folder)"
            if let cur = newest[key], cur.start >= f.start { continue }
            newest[key] = f
        }
        let nowT = now()
        func stable(_ f: DashcamFile) -> Bool {
            guard f.isVideo, recording else { return true }
            let held = lastSizes[f.path] == f.size
            let ended = f.start.addingTimeInterval(max(f.durationS, 60) + 60) < nowT
            if newest["\(f.lens.rawValue)/\(f.folder)"]?.path == f.path { return held && ended }
            return held || ended
        }
        defer { lastSizes = Dictionary(files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a }) }

        let ranges = fetchRanges()
        func isForced(_ f: DashcamFile) -> Bool {
            forced.contains(f.path) || ranges.contains { f.end >= $0.from && f.start <= $0.to }
        }
        let isParked = inPlayback ? true : await parked()
        func wanted(_ f: DashcamFile) -> Bool {
            guard !storage.exists(camera: cameraID, file: f), rows[f.path]?.uploaded != true else { return false }
            guard stable(f) else { report.skippedUnstable += 1; return false }
            return isForced(f) || rules.wants(f, parked: isParked, normalBytesOnPhone: storage.normalBytes(camera: cameraID))
        }

        // 0. Clips someone is waiting on (opened in the player, asked for by the agent) before anything else —
        // and again between every other download, so a clip opened mid-pass doesn't queue behind an hour of footage.
        func takeAsked() async {
            for f in DashcamRules.order(files.filter { forced.contains($0.path) && wanted($0) }) {
                guard await mayContinue() else { return }
                await download(f, camera: cam, cameraID: cameraID, id: clipID(f), report: &report)
            }
        }
        await takeAsked()

        // 1. Events, parking clips and photos first — they matter most.
        let urgent = DashcamRules.order(files.filter { $0.kind != .normal && wanted($0) })
        queuedDownloads = urgent.count
        for f in urgent {
            guard await mayContinue() else { return report }
            await takeAsked()
            guard !storage.exists(camera: cameraID, file: f) else { continue }
            await download(f, camera: cam, cameraID: cameraID, id: clipID(f), report: &report)
        }

        // 2. GPS + speed for every finished clip (two small range reads each).
        phase = .syncing("Reading GPS")
        for f in files where f.isVideo && stable(f) && rows[f.path]?.hasGPS != true && noGPS[f.path] != f.size {
            guard await mayContinue() else { return report }
            let tz = zone.secondsFromGMT(for: f.start)
            if let fixes = try? await cam.gps(f, tzOffset: tz), !fixes.isEmpty {
                if (try? await server.putFixes(clipID: clipID(f), fixes: fixes)) != nil { report.gps += 1 }
            } else {
                noGPS[f.path] = f.size
            }
        }

        // 3. Thumbnails for the library (at most 60 tries a pass).
        phase = .syncing("Fetching thumbnails")
        var tries = 0
        for f in files where stable(f) && rows[f.path] != nil && rows[f.path]?.hasThumb != true && noThumb[f.path] != f.size {
            guard tries < 60, await mayContinue() else { break }
            tries += 1
            guard let data = await cam.thumbnail(f) else { noThumb[f.path] = f.size; continue }
            if (try? await server.putThumb(clipID: clipID(f), jpeg: data)) != nil { report.thumbs += 1 }
        }

        // 4. Normal footage by rule (or asked for), newest first.
        let normal = DashcamRules.order(files.filter { $0.kind == .normal && wanted($0) })
        queuedDownloads = normal.count
        for f in normal {
            guard await mayContinue() else { break }
            await takeAsked()
            guard !storage.exists(camera: cameraID, file: f) else { continue }
            if !isForced(f), !rules.wants(f, parked: isParked, normalBytesOnPhone: storage.normalBytes(camera: cameraID)) { continue }
            await download(f, camera: cam, cameraID: cameraID, id: clipID(f), report: &report)
            if !onCameraProvider() { break }
        }
        queuedDownloads = 0
        return report
    }

    private func download(_ f: DashcamFile, camera cam: DashcamCamera, cameraID: String, id: String,
                          report: inout Report) async {
        let dest = storage.localURL(camera: cameraID, file: f)
        phase = .syncing("Downloading \(f.name)")
        try? await server.setPhone(clipID: id, state: "downloading", error: nil)
        do {
            try await fetcher.download(cam.fileURL(f), to: dest, key: id) { done, total in
                Task { @MainActor in self.downloading = (f.name, done, total > 0 ? total : f.size) }
            }
            downloading = nil
            // Short of the listing → not the whole clip (the camera was still writing it): drop it.
            guard storage.exists(camera: cameraID, file: f) else {
                try? FileManager.default.removeItem(at: dest)
                try? await server.setPhone(clipID: id, state: "failed", error: "download came up short")
                return
            }
            forced.remove(f.path)
            report.downloaded.append(f.path)
            try? await server.setPhone(clipID: id, state: "local", error: nil)
            // The listing's size is rounded to whole KB on Viidure cameras; upload the real one.
            let actual = storage.localSize(camera: cameraID, file: f) ?? f.size
            await uploader.enqueue(clipID: id, local: dest, size: actual, kind: f.kind)
            queuedDownloads = max(0, queuedDownloads - 1)
        } catch {
            downloading = nil
            try? await server.setPhone(clipID: id, state: "failed", error: error.localizedDescription)
        }
    }

    // MARK: Saved fetch requests

    struct FetchRange: Codable, Equatable { var from: Date; var to: Date; var asked: Date }

    /// `dashcam_fetch_range` requests, kept a week so "pull it next time" survives relaunches and
    /// clips recorded after the last listing.
    func fetchRanges() -> [FetchRange] {
        guard let data = defaults.data(forKey: Self.fetchRangesKey),
              let all = try? JSONDecoder().decode([FetchRange].self, from: data) else { return [] }
        return all.filter { $0.asked > now().addingTimeInterval(-7 * 86400) }
    }

    private func saveFetchRanges(_ ranges: [FetchRange]) {
        defaults.set(try? JSONEncoder().encode(ranges), forKey: Self.fetchRangesKey)
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
        // Metered = mobile data, a personal hotspot or Low Data Mode: normal footage waits for free Wi‑Fi.
        let cellular = onCam || (path.map { $0.isExpensive || $0.isConstrained || !$0.usesInterfaceType(.wifi) } ?? false)
        if path?.status == .unsatisfied && !onCam { return }
        let done = await uploader.run(server: uploadServer, cellular: cellular) { id, sent, total in
            Task { @MainActor in self.uploading = (id, sent, total) }
        }
        uploading = nil
        pendingUploads = await uploader.pendingCount
        if !done.isEmpty { await cleanUpUploaded() }
    }

    /// Reconciles the phone's copies with the server: deletes those every destination already has
    /// (unless "keep on phone"), and queues again any the server no longer holds or never got
    /// (its staging was dropped, e.g. the only destination was removed).
    func cleanUpUploaded() async {
        guard let setup = setupProvider() else { return }
        let cameraID = info?.id ?? setup.cameraID
        guard let page = try? await server.clips(DashcamAPI.ClipFilter(state: "on_phone"), cursor: nil, limit: 200) else { return }
        var requeued = false
        for clip in page.clips {
            let f = DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start,
                                durationS: clip.durationS, size: clip.size)
            let url = storage.localURL(camera: clip.cameraID.isEmpty ? cameraID : clip.cameraID, file: f)
            let local = FileManager.default.fileExists(atPath: url.path)
            if clip.uploaded {
                guard !rules.keepOnPhone else { continue }
                if local { try? FileManager.default.removeItem(at: url) }
                try? await server.setPhone(clipID: clip.id, state: "deleted", error: nil)
            } else if local, clip.uploadState == "none", await !uploader.contains(clip.id) {
                await uploader.enqueue(clipID: clip.id, local: url,
                                       size: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? clip.size,
                                       kind: clip.kind)
                requeued = true
            }
        }
        if requeued { kickUploads() }
    }

    // MARK: Requests from Jarvis / the UI

    /// Pull (and upload) every clip that overlaps `from…to`, rules or not. Returns how many matched
    /// the last listing; they are fetched on this pass if the camera is reachable, else on the next.
    @discardableResult
    func fetch(from: Date, to: Date) async -> Int {
        let matches = cameraFiles.filter { $0.end >= from && $0.start <= to }
        matches.forEach { forced.insert($0.path) }
        saveFetchRanges(fetchRanges() + [FetchRange(from: from, to: to, asked: now())])
        passSoon()
        return matches.count
    }

    func pull(_ path: String) {
        forced.insert(path)
        passSoon()
    }

    /// A pass for something just asked for. A pass already running chose its files before the ask,
    /// so wait for it and run another.
    private func passSoon() {
        guard onCameraProvider() else { return }
        Task {
            var waited = 0
            while passRunning && waited < 1800 { try? await Task.sleep(for: .seconds(1)); waited += 1 }
            await self.syncPass()
        }
    }

    /// True once the rules came from the server — Settings won't send edits built on defaults.
    @Published private(set) var rulesLoaded = false

    func refreshRules() async {
        guard let state = try? await server.state() else { return }
        rules = state.rules
        rulesLoaded = true
        // Auto sync means everything comes down: the old "Don't pull normal footage" default is switched
        // over once (the rule can still be changed back in Settings).
        if autoSync, !defaults.bool(forKey: Self.autoAllKey), let api = server as? DashcamAPI {
            defaults.set(true, forKey: Self.autoAllKey)
            if rules.normal == .off {
                rules.normal = .all
                try? await api.updateRules(rules)
            }
        }
    }
    static let autoAllKey = "jc.dashcam.autoSyncPullsAll"

    func refreshCounts() async {
        pendingUploads = await uploader.pendingCount
    }
}
