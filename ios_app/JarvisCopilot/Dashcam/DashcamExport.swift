import CoreLocation
import Foundation
import Photos
import UIKit

/// Getting a clip out of the app: Save to Photos and the share sheet. Both need the clip as a file on the
/// phone, named for when and which camera rather than the camera's own path; a clip the phone only streams
/// is downloaded first, and a .ts is remuxed (Photos and most apps can't open one).
enum DashcamExport {
    /// Where a copy comes from, in the player's order: the phone's copy, the camera (on its Wi‑Fi), the
    /// full-quality Drive file, the uploads the server holds.
    enum Origin: Equatable {
        case phone(URL)
        case camera(URL)
        case drive(destinationID: String, fileID: String)
        case server
        case nowhere
    }

    enum Failure: Error, Equatable, LocalizedError {
        case http(Int)
        case unreachable(String)
        case noPhotosAccess

        var errorDescription: String? {
            switch self {
            case .http(let code): return "The download failed (HTTP \(code))."
            case .unreachable(let why): return why
            case .noPhotosAccess: return "Jarvis can't add to Photos. Allow it in Settings → Privacy & Security → Photos."
            }
        }
    }

    /// `local` only when the phone has the file; `camera` only on the camera's Wi‑Fi, for a file it can
    /// hand over as it is. Drive: the full-quality file, never the light 720p streaming copy. A photo is
    /// asked of the server whatever its upload state, as the player asks it.
    static func origin(of clip: DashcamServerClip, local: URL?, camera: URL?) -> Origin {
        if let local { return .phone(local) }
        if let camera { return .camera(camera) }
        if let drive = clip.driveFile { return .drive(destinationID: drive.destinationID, fileID: drive.fileID) }
        if clip.uploaded || clip.uploadState == "staged" || clip.uploadState == "done" || clip.kind == .photo { return .server }
        return .nowhere
    }

    /// "Dashcam 2026-10-21 16.17.37 Rear.mp4" — the phone's time, and the kind when it isn't a plain drive.
    static func fileName(for clip: DashcamServerClip, ext: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let kind = clip.kind == .event || clip.kind == .parking ? " \(clip.kind.label)" : ""
        return "Dashcam\(kind) \(f.string(from: clip.start)) \(clip.lens.rawValue.capitalized).\(ext)"
    }

    /// Where copies wait while they're saved or shared; emptied before each new export.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DashcamShare", isDirectory: true)
    }

    static func clear(_ dir: URL = directory) { try? FileManager.default.removeItem(at: dir) }

    /// `file` as `name` in `dir`: a hard link (instant, no second copy of a 130 MB clip), else a copy.
    static func stage(_ file: URL, as name: String, in dir: URL = directory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(name)
        try? fm.removeItem(at: out)
        do { try fm.linkItem(at: file, to: out) } catch { try fm.copyItem(at: file, to: out) }
        return out
    }

    /// Cookie-free, like the API's own: the only credential on the wire is the request's header.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    /// Downloads `request` into `dir`, named for its content type (.ts, .mp4, .jpg…), reporting 0…1 as it
    /// goes. Cancelling the calling task cancels the download.
    static func download(_ request: URLRequest, into dir: URL, session: URLSession = session,
                         progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let running = RunningDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: request) { tmp, response, error in
                    running.finish()
                    if let error { return cont.resume(throwing: error) }
                    guard let http = response as? HTTPURLResponse, let tmp else { return cont.resume(throwing: Failure.http(0)) }
                    guard (200..<300).contains(http.statusCode) else { return cont.resume(throwing: Failure.http(http.statusCode)) }
                    let out = dir.appendingPathComponent("download." + ext(for: http))
                    do {
                        try? FileManager.default.removeItem(at: out)
                        try FileManager.default.moveItem(at: tmp, to: out)     // tmp is gone once this returns
                        cont.resume(returning: out)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                running.start(task) { fraction in Task { @MainActor in progress(fraction) } }
            }
        } onCancel: {
            running.cancel()
        }
    }

    private static func ext(for http: HTTPURLResponse) -> String {
        switch http.mimeType?.lowercased() {
        case "video/mp2t": return "ts"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "image/jpeg": return "jpg"
        default:
            let named = URL(fileURLWithPath: http.suggestedFilename ?? "").pathExtension.lowercased()
            return named.isEmpty ? "mp4" : named
        }
    }

    /// What Photos is told: filed at the moment it was recorded, where the car was then.
    struct PhotosItem {
        let file: URL
        let isPhoto: Bool
        let date: Date
        let location: CLLocation?

        init(file: URL, clip: DashcamServerClip, fixes: [DashcamFix]) {
            self.file = file
            isPhoto = clip.kind == .photo
            date = clip.start
            location = fixes.min { $0.t < $1.t }.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        }
    }

    /// Adds the copies to Photos, asking only to add (never to read the library).
    static func saveToPhotos(_ items: [PhotosItem]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.noPhotosAccess }
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.file.lastPathComponent
                request.addResource(with: item.isPhoto ? .photo : .video, fileURL: item.file, options: options)
                request.creationDate = item.date
                request.location = item.location
            }
        }
    }

    /// The system share sheet (Messages, AirDrop, Mail, Files, Save Video…) over the copies, from the
    /// top-most screen. The copies go once it closes.
    @MainActor
    static func share(_ files: [URL]) {
        guard let top = TopViewController.find() else { return }
        let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in clear() }
        // An iPad needs an anchor or the popover assertion fires.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 40, y: top.view.safeAreaInsets.top,
                                                                width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}

/// One download task, its progress, and a cancel that may come before it starts.
private final class RunningDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var watch: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        self.task = task
        watch = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        let cancelled = self.cancelled
        lock.unlock()
        cancelled ? task.cancel() : task.resume()
    }

    func finish() {
        lock.lock(); watch?.invalidate(); watch = nil; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
