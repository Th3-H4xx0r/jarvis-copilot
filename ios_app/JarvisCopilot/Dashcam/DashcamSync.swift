import CoreMotion
import CryptoKit
import Foundation
import Network
import UIKit

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
    @Published private(set) var downloading: (name: String, done: Int64, total: Int64)? {
        didSet { if oldValue == nil, downloading != nil { DashcamSyncBeacon.shared.poke() } }
    }
    /// A transfer to the cloud in flight: it alone (with a camera pass) holds the keepalive.
    @Published private(set) var uploading: (clipID: String, done: Int64, total: Int64)? {
        didSet {
            guard (oldValue == nil) != (uploading == nil) else { return }
            BridgeClient.shared.syncKeepalive()
            if uploading != nil { DashcamSyncBeacon.shared.poke() }
        }
    }
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
    /// The MP4 copies made for Drive and the player, which count against the phone-space cap with the footage.
    var cacheBytes: () -> Int64 = { DashcamPaths.cacheBytes() }
    var parked: () async -> Bool = { await DashcamMotion.shared.isParked() }
    /// On power (charging or full): normal footage held off mobile data may go, and previews are made.
    var charging: () -> Bool = {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }
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
    private var passRunning = false { didSet { passActive = passRunning; BridgeClient.shared.syncKeepalive() } }
    /// A pass is running (the Sync button shows it; tapping it then queues the next pass).
    @Published private(set) var passActive = false
    private var statusWatch: Task<Void, Never>?
    /// Who wants the live status read (the phone's page, the CarPlay screen): it runs while anyone does.
    private var statusWatchers = Set<String>()
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
        // Plugged in: what waited for power (normal footage, previews) can go now.
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kickUploads() }
        }
        wireTopics()
        cleanUpDue = true                       // what reached its destinations while the app was closed
        Task { await refreshRules(); await refreshCounts(); await uploader.retryParked(); kickUploads() }
        // What earlier runs left in the caches, even with cloud backup paused (then no upload run sweeps).
        Task.detached(priority: .utility) { DashcamPlayable.sweep() }
        Task { [uploader] in await uploader.sweepTemp() }
        DashcamSyncBeacon.shared.start()
    }

    /// The app came to the foreground (AppServices): catch up on the server once, then send what can go.
    func foregrounded() {
        guard setupProvider() != nil else { return }
        cleanUpDue = true
        DashcamSyncBeacon.shared.poke()           // an activity can only start now, in the foreground
        Task { await uploader.invalidateDestinations(); kickUploads() }
    }

    // MARK: Server pushes

    private var topicsWired = false

    /// The server pushes what changed on the `dashcam` topic (while the upload loop listens) instead of
    /// the loop asking every 15–30 s.
    private func wireTopics() {
        guard !topicsWired else { return }
        topicsWired = true
        BridgeTopics.shared.on("dashcam") { [weak self] data in self?.pushed(data) }
        BridgeTopics.shared.onResync { [weak self] in self?.resynced() }
    }

    /// `what` names the changes: `destinations`, `rules`, `clips`. A bare push counts as all of them.
    func pushed(_ data: [String: Any]) {
        guard setupProvider() != nil else { return }
        var what = Set(data["what"] as? [String] ?? (data["what"] as? String).map { [$0] } ?? [])
        if what.isEmpty { what = ["destinations", "rules", "clips"] }
        if what.contains("clips") { cleanUpDue = true }
        if what.contains("destinations") { destinationsChanged() }
        if what.contains("rules") { Task { await refreshRules(); kickUploads() } }
        kickUploads()
    }

    /// The socket came back: anything pushed while it was down was missed. Only a loop that was
    /// listening can have missed anything (no loop = nothing waited on a push).
    func resynced() {
        guard setupProvider() != nil, uploadLoop != nil else { return }
        cleanUpDue = true
        Task { await uploader.invalidateDestinations(); kickUploads() }
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

    // MARK: Deleting from the camera

    static let cameraDeletesKey = "jc.dashcam.cameraDeletes"
    /// Card paths to delete from the dashcam: kept until done, so a delete asked for away from the camera
    /// happens the next time the phone is on its Wi‑Fi.
    var pendingCameraDeletes: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.cameraDeletesKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.cameraDeletesKey) }
    }

    /// Deletes a clip from the card now when on the camera's Wi‑Fi (true), otherwise queues it.
    func deleteFromCamera(_ path: String) async -> Bool {
        pendingCameraDeletes.insert(path)
        guard onCameraProvider(), let setup = setupProvider(), let cam = cameraFactory(setup) else { return false }
        let f = DashcamFile(path: path, kind: .normal, lens: .front, start: now(), durationS: 0, size: 0)
        if (try? await cam.delete(f)) != nil { pendingCameraDeletes.remove(path); return true }
        passSoon()                    // the pass retries it, in playback mode when parked
        return false
    }

    private func applyCameraDeletes(_ files: [DashcamFile], camera cam: DashcamCamera) async -> [DashcamFile] {
        var pending = pendingCameraDeletes
        let listed = Set(files.map(\.path))
        pending = pending.filter { listed.contains($0) }          // already gone from the card
        var refused: [DashcamFile] = []
        for f in files where pending.contains(f.path) {
            if (try? await cam.delete(f)) != nil { pending.remove(f.path) } else { refused.append(f) }
        }
        // Some firmware only deletes in playback mode — only ever while parked, recording restored after.
        if !refused.isEmpty, setupProvider()?.family == .viidure, await parked(), !liveActive {
            let wasRecording = try? await cam.isRecording()
            maybeInPlayback = true
            if (try? await cam.playback(true)) != nil {
                for f in refused where (try? await cam.delete(f)) != nil { pending.remove(f.path) }
            }
            await leavePlayback(cam, wasRecording: wasRecording)
        }
        let asked = pendingCameraDeletes.intersection(listed)          // deleted now, or still waiting
        pendingCameraDeletes = pending
        return files.filter { !asked.contains($0.path) }               // neither comes back into the library
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

    /// Polls the status every few seconds while a dashcam screen is really on screen (`owner`: "page",
    /// "carplay"). The phone's page lets go in the background without stopping CarPlay's.
    func watchStatus(_ on: Bool, by owner: String) {
        if on { statusWatchers.insert(owner) } else { statusWatchers.remove(owner) }
        guard !statusWatchers.isEmpty else {
            statusWatch?.cancel()
            statusWatch = nil
            return
        }
        guard statusWatch == nil else { return }
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
    /// Remembered across launches: a finished clip recorded without a GPS lock never gains one, and a
    /// camera whose GPS is out re-read every clip on every launch.
    private lazy var noGPS: [String: Int64] = {
        (defaults.dictionary(forKey: Self.noGPSKey) as? [String: NSNumber] ?? [:]).mapValues(\.int64Value)
    }()
    static let noGPSKey = "jc.dashcam.noGPS"
    /// The longest the GPS step may take in one pass; the rest waits for the next.
    static let gpsBudget: TimeInterval = 30

    private func markNoGPS(_ f: DashcamFile, listed: [DashcamFile]) {
        noGPS[f.path] = f.size
        if noGPS.count > 3000 {                     // clips long gone from the card
            let onCard = Set(listed.map(\.path))
            noGPS = noGPS.filter { onCard.contains($0.key) }
        }
        defaults.set(noGPS.mapValues { NSNumber(value: $0) }, forKey: Self.noGPSKey)
    }
    /// Clips that gave no preview (camera or file), remembered across launches like `noGPS`.
    private lazy var noThumb: [String: Int64] = {
        (defaults.dictionary(forKey: Self.noThumbKey) as? [String: NSNumber] ?? [:]).mapValues(\.int64Value)
    }()
    static let noThumbKey = "jc.dashcam.noThumb"
    static let thumbBudget: TimeInterval = 20

    private func markNoThumb(_ f: DashcamFile, listed: [DashcamFile]) {
        noThumb[f.path] = f.size
        if noThumb.count > 3000 {
            let onCard = Set(listed.map(\.path))
            noThumb = noThumb.filter { onCard.contains($0.key) }
        }
        defaults.set(noThumb.mapValues { NSNumber(value: $0) }, forKey: Self.noThumbKey)
    }
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
        // Deletions asked for while away from the camera, done before anything else (and never listed).
        if !pendingCameraDeletes.isEmpty { files = await applyCameraDeletes(files, camera: cam) }
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
        // Queued while the server didn't know them yet: it does now, so a "clip not found" means deleted.
        if !rows.isEmpty { await uploader.confirm(Set(rows.values.map(\.id))) }
        /// Deleted on this phone in the last two weeks (read once a pass, not once a file).
        let deleted = DashcamTombstones.ids(defaults: defaults)
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
        // "Charging only": normal footage waits for the charger (checked again every pass).
        let onPower = charging()
        // Normal footage on the phone, walked once a pass (it used to be walked for every listed clip, on
        // the main thread — thousands of file checks every 20 s that made the whole page sluggish).
        // The cap also covers the MP4 copies made for Drive and the player: they once took 130 GB on their own.
        var normalOnPhone = storage.normalBytes(camera: cameraID) + cacheBytes()
        func wanted(_ f: DashcamFile) -> Bool {
            guard !storage.exists(camera: cameraID, file: f), rows[f.path]?.uploaded != true else { return false }
            // Deleted on this phone (even everywhere, and the card lists it again): only a pull by hand brings it back.
            if !deleted.isEmpty, deleted.contains(clipID(f)), !forced.contains(f.path) { return false }
            // Deleted from the phone on purpose: stays deleted until "Download again".
            if rows[f.path]?.phoneDeleted == true && !isForced(f) { return false }
            guard stable(f) else { report.skippedUnstable += 1; return false }
            return isForced(f) || rules.wants(f, parked: isParked, charging: onPower, normalBytesOnPhone: normalOnPhone)
        }

        // 0. Clips someone is waiting on (opened in the player, asked for by the agent) before anything else —
        // and again between every other download, so a clip opened mid-pass doesn't queue behind an hour of footage.
        func takeAsked() async {
            for f in DashcamRules.order(files.filter { forced.contains($0.path) && wanted($0) }) {
                guard await mayContinue() else { return }
                await download(f, camera: cam, cameraID: cameraID, id: clipID(f), known: rows[f.path] != nil, report: &report)
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
            await download(f, camera: cam, cameraID: cameraID, id: clipID(f), known: rows[f.path] != nil, report: &report)
        }

        // 2. GPS + speed (two small range reads a clip; none for clips already on the phone), newest first and
        // within a time budget. A camera with no GPS lock, or one too busy to answer, never holds up the
        // thumbnails and downloads: after a few clips in a row without a fix, or a few errors, it waits.
        let needGPS = files.filter { $0.isVideo && stable($0) && rows[$0.path]?.hasGPS != true && noGPS[$0.path] != $0.size }
            .sorted { $0.start > $1.start }
        let gpsDeadline = Date().addingTimeInterval(Self.gpsBudget)
        var noFixRun = 0, errorRun = 0
        for (i, f) in needGPS.enumerated() {
            guard await mayContinue() else { return report }
            guard Date() < gpsDeadline, noFixRun < 5, errorRun < 3 else { break }
            phase = .syncing("Reading GPS (\(i + 1) of \(needGPS.count))")
            let tz = zone.secondsFromGMT(for: f.start)
            var fixes: [DashcamFix] = []
            if storage.exists(camera: cameraID, file: f) {
                let url = storage.localURL(camera: cameraID, file: f)
                let raw = await Task.detached(priority: .utility) { DashcamRemux.tailFixes(url) }.value
                fixes = DashcamGPS.align(raw, clipStart: f.start, duration: f.durationS, tzOffset: tz)
            }
            if fixes.isEmpty {
                do { fixes = try await cam.gps(f, tzOffset: tz) } catch { errorRun += 1; continue }
            }
            errorRun = 0
            if fixes.isEmpty {
                noFixRun += 1
                markNoGPS(f, listed: files)
            } else {
                noFixRun = 0
                if (try? await server.putFixes(clipID: clipID(f), fixes: fixes)) != nil { report.gps += 1 }
            }
        }

        // 3. Thumbnails for the library, newest first and within a budget like GPS: a slow camera or clips
        // without a preview must never hold up the downloads ("Fetching thumbnails" sat for minutes).
        let needThumb = files.filter { stable($0) && rows[$0.path] != nil && rows[$0.path]?.hasThumb != true && noThumb[$0.path] != $0.size }
            .sorted { $0.start > $1.start }
        let thumbDeadline = Date().addingTimeInterval(Self.thumbBudget)
        var thumbMisses = 0
        for (i, f) in needThumb.enumerated() {
            guard await mayContinue() else { return report }
            guard Date() < thumbDeadline, thumbMisses < 3 else { break }
            phase = .syncing("Fetching thumbnails (\(i + 1) of \(needThumb.count))")
            // A clip already on the phone gives its preview without touching the camera.
            var preview: Data?
            if storage.exists(camera: cameraID, file: f) {
                let url = storage.localURL(camera: cameraID, file: f)
                preview = await Task.detached(priority: .utility) { DashcamRemux.embeddedJPEG(file: url) }.value
            }
            if preview == nil { preview = await cam.thumbnail(f) }
            guard let data = preview else { thumbMisses += 1; markNoThumb(f, listed: files); continue }
            thumbMisses = 0
            if (try? await server.putThumb(clipID: clipID(f), jpeg: data)) != nil { report.thumbs += 1 }
        }

        // 4. Normal footage by rule (or asked for), newest first.
        let normal = DashcamRules.order(files.filter { $0.kind == .normal && wanted($0) })
        queuedDownloads = normal.count
        for f in normal {
            guard await mayContinue() else { break }
            await takeAsked()
            guard !storage.exists(camera: cameraID, file: f) else { continue }
            if !isForced(f), !rules.wants(f, parked: isParked, charging: onPower, normalBytesOnPhone: normalOnPhone) { continue }
            await download(f, camera: cam, cameraID: cameraID, id: clipID(f), known: rows[f.path] != nil, report: &report)
            if storage.exists(camera: cameraID, file: f) { normalOnPhone += f.size }
            if !onCameraProvider() { break }
        }
        queuedDownloads = 0
        return report
    }

    /// `known`: the server listed the clip this pass (its inventory answered). Only then does a
    /// "clip not found" mean deleted — otherwise the server just hasn't heard of it yet.
    private func download(_ f: DashcamFile, camera cam: DashcamCamera, cameraID: String, id: String, known: Bool,
                          report: inout Report) async {
        // A pull by hand ("Download again") is the one thing that brings back a clip deleted here.
        if forced.contains(f.path) { DashcamTombstones.remove(id, defaults: defaults) }
        guard !DashcamTombstones.contains(id, defaults: defaults) else { return }
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
            // Deleted while it came down (here, or everywhere from elsewhere): the delete wins. Two clips
            // deleted mid-download came back this way and asked the server to upload them all week.
            var deleted = DashcamTombstones.contains(id, defaults: defaults)
            if !deleted {
                do { try await server.setPhone(clipID: id, state: "local", error: nil) }
                catch { deleted = known && DashcamAPI.isClipGone(error) }
            }
            if deleted {
                try? FileManager.default.removeItem(at: dest)
                DashcamTombstones.add(id, defaults: defaults)
                queuedDownloads = max(0, queuedDownloads - 1)
                return
            }
            report.downloaded.append(f.path)
            // The listing's size is rounded to whole KB on Viidure cameras; upload the real one.
            let actual = storage.localSize(camera: cameraID, file: f) ?? f.size
            await uploader.enqueue(clipID: id, local: dest, size: actual, kind: f.kind, confirmed: known)
            kickUploads()                                   // uploads run beside the downloads
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

    /// Clips are moving (a camera pass, or a transfer in flight): the app stays awake in the background.
    /// Jobs merely waiting (a backoff, the rules, no network) don't hold it — that kept it awake all night
    /// for two clips that could never go.
    var holdsKeepalive: Bool { passRunning || uploading != nil }

    /// The upload loop: one at a time, asleep while nothing can go, woken by `kickUploads()`.
    /// Uploads run beside the camera sync, not after it: a clip goes up as soon as it's on the phone, and the
    /// phone's copy goes once every destination has it. The loop lives while there is anything to send or
    /// anything on the server still on its way to a destination.
    private var uploadLoop: Task<Void, Never>?
    private var uploadLoopID: UUID?
    /// Set by `kickUploads()` while the loop runs: it goes round again instead of sleeping.
    private var kicked = false
    private var napper: Task<Bool, Never>?
    /// Reconcile with the server on the next round: launch, foreground, a `dashcam {clips}` push, a resync.
    private var cleanUpDue = false
    /// Clips on the server not yet at every destination, as of the last clean-up.
    private var relaying = 0
    /// `uploader.run` is in flight: progress landing after it ended is dropped, or a stale "uploading"
    /// would hold the keepalive and the Live Activity.
    private var uploadRunning = false
    /// The loop subscribed to the `dashcam` push topic.
    private var listening = false
    /// The longest it sleeps with jobs waiting and nothing due: what a missed push costs at most.
    static let maxNap: TimeInterval = 1800
    /// "Upload only when parked" and the car isn't: no event says it parked, so motion (local) is asked
    /// again every minute.
    static let parkedNap: TimeInterval = 60
    static let topicOwner = "dashcam.uploads"

    /// Starts the upload loop, or wakes the one asleep. Called for every reason a clip might go now:
    /// a new job, a network path change, the rules, a push, foregrounding.
    func kickUploads() {
        guard uploadLoop == nil else {
            kicked = true
            napper?.cancel()
            return
        }
        let id = UUID()
        uploadLoopID = id
        uploadLoop = Task { [weak self] in
            // No loop was listening for pushes: what it knew about the destinations may be stale.
            await self?.uploader.invalidateDestinations()
            while !Task.isCancelled {
                guard let self else { return }
                self.kicked = false
                let pending = await self.uploader.pendingCount
                self.pendingUploads = pending
                let waitingForPark = pending > 0 ? await self.uploadOnce() : false
                if self.cleanUpDue {
                    self.cleanUpDue = false
                    await self.cleanUpUploaded()
                }
                let left = await self.uploader.pendingCount
                self.pendingUploads = left
                if left == 0 && self.relaying == 0 { break }
                if self.kicked || Task.isCancelled { continue }
                if !self.listening {
                    self.listening = true
                    BridgeTopics.shared.want("dashcam", owner: Self.topicOwner, every: 0)
                }
                // Asleep until the earliest retry (a backoff, the quota, a sign-in hold) or a kick.
                let due = await self.uploader.nextDue(now: Date())
                var nap = min(due.map { $0.timeIntervalSinceNow } ?? Self.maxNap, Self.maxNap)
                if waitingForPark { nap = min(nap, Self.parkedNap) }
                let ranOut = await self.nap(max(1, nap))
                // Something may have reached its destinations with no push to say so (an older server).
                if ranOut && self.relaying > 0 { self.cleanUpDue = true }
            }
            if let self, self.uploadLoopID == id { self.endUploadLoop() }
        }
    }

    /// Sleeps up to `seconds`; true when it ran out, false when a kick (or a cancel) cut it short.
    private func nap(_ seconds: TimeInterval) async -> Bool {
        guard !kicked else { return false }
        let sleeper = Task { () -> Bool in (try? await Task.sleep(for: .seconds(seconds))) != nil }
        napper = sleeper
        let ranOut = await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        napper = nil
        return ranOut
    }

    private func endUploadLoop() {
        uploadLoop = nil
        uploadLoopID = nil
        napper?.cancel()
        napper = nil
        if listening {
            listening = false
            BridgeTopics.shared.drop("dashcam", owner: Self.topicOwner)
        }
        // Motion ran for "upload only when parked"; the camera pass still wants it on the camera's Wi‑Fi.
        if !onCameraProvider() { DashcamMotion.shared.stop() }
    }

    /// One round over the queue (no request at all when nothing may go). True when clips wait only for
    /// the car to park.
    @discardableResult
    func uploadOnce() async -> Bool {
        let path = internetPath
        let onCam = onCameraProvider()
        // On the camera's Wi‑Fi the internet goes over mobile data (LTE); off it, Wi‑Fi unless only cellular
        // is up. Metered = mobile data, a personal hotspot or Low Data Mode — what the upload rules gate.
        let cellular = onCam || (path.map { $0.isExpensive || $0.isConstrained || !$0.usesInterfaceType(.wifi) } ?? false)
        if path?.status == .unsatisfied && !onCam { return false }
        let rules = self.rules
        guard rules.upload else { return false }
        let isParked = rules.uploadWhen == .parked ? await parked() : true
        let onPower = charging()
        let throttle = DashcamThrottle()
        let keep = rules.keepOnPhone
        let server = self.server
        uploadRunning = true
        let done = await uploader.run(server: uploadServer, cellular: cellular,
                                      allow: { rules.mayUpload($0, metered: cellular, parked: isParked, charging: onPower) },
                                      previews: onPower,
                                      finished: { id, path in
            // In the cloud: the phone's copy goes at once, not at the next clean-up (which a long run never reached).
            guard !keep else { return }
            try? FileManager.default.removeItem(atPath: path)
            Task { try? await server.setPhone(clipID: id, state: "deleted", error: nil) }
        }) { id, sent, total in
            guard throttle.pass(final: sent >= total) else { return }
            Task { @MainActor in
                guard self.uploadRunning else { return }
                self.uploading = (id, sent, total)
                if sent >= total { self.pendingUploads = await self.uploader.pendingCount }
            }
        }
        uploadRunning = false
        uploading = nil
        pendingUploads = await uploader.pendingCount
        if await !uploader.expiredSignIns().isEmpty {
            uploadNote = "Google Drive sign-in expired — clips wait on the phone. Sign in again in Destinations."
        } else if let until = await uploader.driveQuotaUntil, until > Date() {
            uploadNote = "Google Drive's shared rclone key is out of quota — retrying by itself. Your own Google key fixes it (Destinations)."
        } else if rules.uploadWhen == .charging, !onPower, pendingUploads > 0 {
            uploadNote = "Clips upload once the phone is charging."
        } else {
            uploadNote = nil
        }
        if !done.isEmpty { await cleanUpUploaded() }
        return !isParked
    }

    /// Why uploads are waiting, for the page header (nil when they aren't).
    @Published private(set) var uploadNote: String?

    /// The Pause/Resume cloud backup button: the upload rule, and the run in flight stops at once.
    func setCloudBackup(_ on: Bool) {
        rules.upload = on
        let r = rules
        Task { try? await DashcamAPI().updateRules(r) }
        if on { kickUploads() } else { uploadLoop?.cancel(); endUploadLoop(); uploading = nil }
    }

    /// A destination was added or changed (here, or pushed from elsewhere): clips parked on "no destination"
    /// or a dead sign-in go now, with the new list.
    func destinationsChanged() {
        Task {
            await uploader.invalidateDestinations()
            await uploader.retryParked()
            kickUploads()
        }
    }

    /// Reconciles the phone's copies with the server: deletes those every destination already has
    /// (unless "keep on phone"), and queues again any the server no longer holds or never got
    /// (its staging was dropped, e.g. the only destination was removed). Never a clip deleted here.
    /// Returns how many clips are on the server but not yet at every destination (worth checking again).
    @discardableResult
    func cleanUpUploaded() async -> Int {
        guard let setup = setupProvider() else { return 0 }
        let cameraID = info?.id ?? setup.cameraID
        guard let page = try? await server.clips(DashcamAPI.ClipFilter(state: "on_phone"), cursor: nil, limit: 200) else { return relaying }
        await uploader.confirm(Set(page.clips.map(\.id)))
        let deleted = DashcamTombstones.ids(defaults: defaults)
        var requeued = false
        var count = 0
        for clip in page.clips where !deleted.contains(clip.id) {
            let f = DashcamFile(path: clip.path, kind: clip.kind, lens: clip.lens, start: clip.start,
                                durationS: clip.durationS, size: clip.size)
            let url = storage.localURL(camera: clip.cameraID.isEmpty ? cameraID : clip.cameraID, file: f)
            let local = FileManager.default.fileExists(atPath: url.path)
            if clip.uploaded {
                guard !rules.keepOnPhone else { continue }
                if local { try? FileManager.default.removeItem(at: url) }
                try? await server.setPhone(clipID: clip.id, state: "deleted", error: nil)
            } else if clip.uploadState == "staged" || clip.uploading {
                count += 1
            } else if local, clip.uploadState == "none", await !uploader.contains(clip.id) {
                await uploader.enqueue(clipID: clip.id, local: url,
                                       size: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? clip.size,
                                       kind: clip.kind)
                requeued = true
            }
        }
        relaying = count
        if requeued { kickUploads() }
        return count
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

    /// Send the rules as they stand now (Settings edits `rules` first). Nil when saved,
    /// else the line to show.
    func saveRules() async -> String? {
        do {
            try await DashcamAPI().updateRules(rules)
            return nil
        } catch {
            return "Couldn't save the rules: \(error.localizedDescription)"
        }
    }

    func refreshCounts() async {
        pendingUploads = await uploader.pendingCount
    }
}
