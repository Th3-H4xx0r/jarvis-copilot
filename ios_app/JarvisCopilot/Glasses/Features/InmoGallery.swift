import Combine
import Foundation
import Photos
import UIKit

/// The glasses side of the gallery: the inventory and the Wi-Fi file transfer.
@MainActor
protocol InmoMediaFetching: AnyObject {
    var inventory: [InmoMediaItem] { get }
    /// A Wi-Fi session is open (a batch, a single download, or the notes' photo fetch).
    var busy: Bool { get }
    var inventoryChanges: AnyPublisher<[InmoMediaItem], Never> { get }
    func refresh() async throws
    func openSession() async throws
    func fetch(_ item: InmoMediaItem) async throws -> URL
    func closeSession() async
    func cancel()
}

extension InmoMediaTransfer: InmoMediaFetching {
    var inventoryChanges: AnyPublisher<[InmoMediaItem], Never> { $items.eraseToAnyPublisher() }
}

/// The camera roll, add-only (Jarvis never reads the library).
@MainActor
protocol InmoPhotosSaving {
    func authorize() async -> Bool
    func save(_ file: URL, name: String, isPhoto: Bool, date: Date) async throws
}

struct InmoPhotosSaver: InmoPhotosSaving {
    func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
    func save(_ file: URL, name: String, isPhoto: Bool, date: Date) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            request.addResource(with: isPhoto ? .photo : .video, fileURL: file, options: options)
            request.creationDate = date
        }
    }
}

/// The glasses gallery: what's on the glasses merged with what Jarvis already saved, and
/// "Save & download all" — one Wi-Fi session, photos first, each item into the camera roll, its
/// preview kept, Jarvis's own copy removed.
@MainActor
final class InmoGallery: ObservableObject {
    struct Run: Equatable {
        var done: Int
        var total: Int
        var current: String?
    }

    static let shared = InmoGallery(fetcher: InmoMediaTransfer.shared, saver: InmoPhotosSaver(), library: .standard)

    @Published private(set) var entries: [InmoGalleryEntry] = []
    @Published private(set) var other: [InmoMediaItem] = []
    @Published private(set) var run: Run?
    @Published private(set) var message: String?
    @Published private(set) var failed: Set<String> = []

    let library: InmoMediaLibrary
    private let fetcher: InmoMediaFetching
    private let saver: InmoPhotosSaving
    private var cancelled = false
    /// Only cancel the transfer once this batch owns its session — before that it may be someone else's.
    private var ownsSession = false
    private var watch: AnyCancellable?

    init(fetcher: InmoMediaFetching, saver: InmoPhotosSaving, library: InmoMediaLibrary) {
        self.fetcher = fetcher; self.saver = saver; self.library = library
        if fetcher.busy == false { library.sweepLeftovers() }
        reload()
        watch = fetcher.inventoryChanges.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
    }

    /// Items on the glasses that aren't in the camera roll yet.
    var unsaved: [InmoGalleryItem] { entries.compactMap { $0.saved ? nil : $0.item } }

    func reload() {
        let grouped = InmoMediaGrouping.group(fetcher.inventory)
        entries = InmoMediaLibrary.merge(live: grouped.gallery, records: library.records)
        other = grouped.other
    }

    func refresh() async {
        do { try await fetcher.refresh(); message = nil } catch { message = error.localizedDescription }
        reload()
    }

    /// Starts saving in the background and returns how many items it will save.
    @discardableResult
    func startSaveAll(keys: [String]? = nil) throws -> Int {
        guard run == nil else { throw InmoMediaError(message: "Already saving from the glasses.") }
        guard !fetcher.busy else { throw InmoMediaError(message: "Another glasses download is running; try again when it finishes.") }
        let todo = pending(keys)
        guard !todo.isEmpty else { throw InmoMediaError(message: "Everything on the glasses is already in your camera roll.") }
        begin(todo)
        Task { await perform(todo) }
        return todo.count
    }

    /// The button or a tile: everything unsaved (`nil`), or just these items.
    func save(keys: [String]?) {
        do { try startSaveAll(keys: keys) } catch { message = error.localizedDescription }
    }

    func cancel() {
        guard run != nil else { return }
        cancelled = true
        if ownsSession { fetcher.cancel() }
    }

    /// The batch, awaited (tests and `startSaveAll`).
    func saveAll(keys: [String]? = nil) async {
        guard run == nil, !fetcher.busy else { return }
        let todo = pending(keys)
        guard !todo.isEmpty else { return }
        begin(todo)
        await perform(todo)
    }

    private func begin(_ todo: [InmoGalleryItem]) {
        run = Run(done: 0, total: todo.count)
        cancelled = false; message = nil
    }

    /// Photos first (fast previews), then videos; newest first within each.
    private func pending(_ keys: [String]?) -> [InmoGalleryItem] {
        let wanted = keys.map(Set.init)
        return unsaved.filter { wanted?.contains($0.key) ?? true }
            .sorted { $0.kind != $1.kind ? $0.kind == .photo : $0.capturedAt > $1.capturedAt }
    }

    private func perform(_ todo: [InmoGalleryItem]) async {
        let idle = UIApplication.shared.isIdleTimerDisabled
        // A locked screen drops the glasses' join-once network mid-batch.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { run = nil; ownsSession = false; UIApplication.shared.isIdleTimerDisabled = idle; reload() }
        guard await saver.authorize() else {
            message = "Allow Jarvis to add to Photos (Settings → Jarvis → Photos) to save from the glasses."
            return
        }
        guard !cancelled else { message = "Cancelled."; return }
        do { try await fetcher.openSession() } catch {
            message = cancelled ? "Cancelled." : error.localizedDescription
            return
        }
        ownsSession = true
        if cancelled { fetcher.cancel() }
        var saved = 0, silent = 0
        var lost: String?
        for item in todo {
            if cancelled { break }
            run?.current = item.key
            do {
                if try await saveOne(item) == false { silent += 1 }
                saved += 1
                failed.remove(item.key)
            } catch is CancellationError {
                cancelled = true
                break
            } catch let error as InmoMediaConnectionError {
                // The glasses' network is gone; every other item would wait out the same timeout.
                failed.insert(item.key)
                lost = error.localizedDescription
                break
            } catch {
                if cancelled { break }
                failed.insert(item.key)
            }
            run?.done += 1
            reload()
        }
        await fetcher.closeSession()
        try? library.persist()
        let left = todo.count - saved
        var summary = "Saved \(saved) to your camera roll."
        if silent > 0 { summary += " \(silent) video\(silent == 1 ? "" : "s") without sound." }
        if let lost { summary += " Stopped: \(lost)" }
        else if left > 0 { summary += cancelled ? " Cancelled — \(left) not saved." : " \(left) failed; try again." }
        message = summary
    }

    /// Returns whether a video kept its sound (photos: true).
    private func saveOne(_ item: InmoGalleryItem) async throws -> Bool {
        guard let picture = item.picture else { throw InmoMediaError(message: "Nothing to save.") }
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let local = try await fetcher.fetch(picture)
        files.append(local)
        var toSave = local, name = picture.name, withSound = true
        if item.kind == .video {
            var sound: URL?
            if let part = item.sound {
                // A transfer error leaves the item unsaved and retryable; only a missing or
                // undecodable sound file gives a picture-only save.
                let url = try await fetcher.fetch(part)
                files.append(url); sound = url
            }
            let work = library.directory.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            name = (picture.name as NSString).deletingPathExtension + ".mp4"
            let output = work.appendingPathComponent(UUID().uuidString + "-" + name)
            files.append(output)
            withSound = await InmoVideoMerger.merge(video: local, opus: sound, to: output)
            toSave = output
        }
        if cancelled { throw CancellationError() }
        try await saver.save(toSave, name: name, isPhoto: item.kind == .photo, date: item.capturedAt)
        // In Photos now: record it before anything else can fail, so it's never saved twice. A failed
        // write keeps the memory copy and is retried at the end of the batch — the item still counts.
        var record = InmoGalleryRecord(key: item.key, kind: item.kind, capturedAt: item.capturedAt,
                                       parts: Dictionary(item.parts.map { ($0.name, $0.size) }, uniquingKeysWith: { $1 }),
                                       savedAt: Date(), withoutSound: item.kind == .video && !withSound)
        try? library.record(record)
        if let thumb = try? await InmoMediaThumbnail.make(toSave, kind: item.kind) {
            let file = item.key + ".jpg"
            try? FileManager.default.createDirectory(at: library.thumbsDirectory, withIntermediateDirectories: true)
            if (try? thumb.jpeg.write(to: library.thumbsDirectory.appendingPathComponent(file), options: .atomic)) != nil {
                record.thumb = file
            }
            record.duration = thumb.duration
            try? library.record(record)
        }
        return withSound
    }

    /// For `glasses_media_list`.
    func snapshot() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var result: [String: Any] = [
            "gallery": entries.map { entry -> [String: Any] in
                ["key": entry.key, "kind": entry.kind.rawValue, "captured_at": iso.string(from: entry.capturedAt),
                 "saved": entry.saved, "without_sound": entry.record?.withoutSound ?? false,
                 "on_glasses": entry.item != nil, "failed": failed.contains(entry.key)]
            },
            "unsaved": unsaved.count,
        ]
        if let run { result["run"] = ["done": run.done, "total": run.total, "current": run.current as Any? ?? NSNull()] }
        if let message { result["message"] = message }
        return result
    }
}
