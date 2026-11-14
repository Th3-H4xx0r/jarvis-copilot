import AVFoundation
import Photos
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What the phone knows about a file before it goes up: its kind, and the thumbnail the vault
/// shows for it (made here, so the server never runs plaintext media through anything).
struct VaultMediaInfo {
    var kind: VaultItem.Kind
    var mime: String
    var size: Int64
    var duration: Double?
    var width: Int?
    var height: Int?
    var pages: Int?
    var thumbJPEG: Data?

    static func inspect(_ url: URL) async -> VaultMediaInfo {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: VaultItem.Kind
        if type.conforms(to: .pdf) { kind = .pdf }
        else if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { kind = .video }
        else { kind = .file }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var info = VaultMediaInfo(kind: kind, mime: type.preferredMIMEType ?? "application/octet-stream", size: size)
        switch kind {
        case .video:
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration) { info.duration = d.seconds.isFinite ? d.seconds : nil }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = natural.applying(transform)
                info.width = Int(abs(r.width)); info.height = Int(abs(r.height))
            }
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                info.width = props[kCGImagePropertyPixelWidth] as? Int
                info.height = props[kCGImagePropertyPixelHeight] as? Int
            }
        case .pdf:
            info.pages = PDFDocument(url: url)?.pageCount
        default:
            break
        }
        info.thumbJPEG = await thumbnail(url)
        return info
    }

    /// QuickLook makes thumbnails for photos, videos, PDFs and most documents alike.
    static func thumbnail(_ url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 640, height: 640),
                                                   scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return rep.uiImage.jpegData(compressionQuality: 0.78)
    }
}

/// Uploads into the vault, one at a time, through the write-only inbox: 8 MB chunks, each
/// retried and the whole thing resumable, so a 2 GB video survives a dropped connection — and
/// a vault lock, since the inbox needs no session.
@MainActor
final class VaultUploads: ObservableObject {
    static let shared = VaultUploads()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let file: URL
        let filename: String
        let parentID: String
        /// A copy this app made (Photos, camera): cleaned up once it's up.
        let ownsFile: Bool
        let assetID: String?
        var uploadID: String?
        var progress: Double = 0
        var failed: String?
        var done = false
    }

    @Published private(set) var jobs: [Job] = []
    /// Library photos to take out of Photos once their uploads finish (his "remove after import").
    private var removeFromPhotos: Set<String> = []
    private var running = false
    private let api: VaultAPI
    var onFinished: (() -> Void)?

    init(api: VaultAPI = VaultAPI()) { self.api = api }

    var active: [Job] { jobs.filter { !$0.done } }

    var summary: String? {
        let left = active
        guard !left.isEmpty else { return nil }
        if !left.contains(where: { $0.failed == nil }) {
            return left.count == 1 ? "Upload stopped" : "\(left.count) uploads stopped"
        }
        let current = left.first { $0.failed == nil }
        let pct = Int(((current?.progress ?? 0) * 100).rounded())
        return left.count == 1 ? "Uploading · \(pct)%" : "Uploading \(left.count) · \(pct)%"
    }

    func enqueue(_ file: URL, filename: String? = nil, parent: String, ownsFile: Bool, assetID: String? = nil,
                 removeOriginal: Bool = false) {
        jobs.append(Job(file: file, filename: filename ?? file.lastPathComponent, parentID: parent,
                        ownsFile: ownsFile, assetID: assetID))
        if removeOriginal, let assetID { removeFromPhotos.insert(assetID) }
        pump()
    }

    /// Gives up on the stopped uploads, and deletes the copies this app made for them.
    func discardFailed() {
        for job in jobs where job.failed != nil && job.ownsFile {
            try? FileManager.default.removeItem(at: job.file)
        }
        jobs.removeAll { $0.failed != nil }
    }

    func retryFailed() {
        for i in jobs.indices where jobs[i].failed != nil { jobs[i].failed = nil }
        pump()
    }

    private func pump() {
        guard !running else { return }
        guard let index = jobs.firstIndex(where: { !$0.done && $0.failed == nil }) else {
            finishBatch()
            return
        }
        running = true
        let job = jobs[index]
        Task {
            let outcome = await upload(job)
            if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                switch outcome {
                case .success(let uploadID):
                    jobs[i].uploadID = uploadID
                    jobs[i].done = true
                    jobs[i].progress = 1
                    if job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
                case .failure(let error):
                    jobs[i].failed = apiErrorLine(error)
                }
            }
            running = false
            onFinished?()
            pump()
        }
    }

    private func finishBatch() {
        let finished = jobs.filter(\.done)
        let originals = finished.compactMap(\.assetID).filter { removeFromPhotos.contains($0) }
        jobs.removeAll(where: \.done)
        removeFromPhotos.subtract(originals)
        guard !originals.isEmpty else { return }
        Task { await Self.removeOriginals(originals) }
    }

    /// iOS shows its own confirmation before anything leaves Photos.
    private static func removeOriginals(_ ids: [String]) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            JcLog.services.notice("vault: originals stayed in Photos: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setProgress(_ id: UUID, _ value: Double) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].progress = value }
    }

    private func upload(_ job: Job) async -> Result<String, Error> {
        do {
            let scoped = job.file.startAccessingSecurityScopedResource()
            defer { if scoped { job.file.stopAccessingSecurityScopedResource() } }
            let info = await VaultMediaInfo.inspect(job.file)
            guard info.size <= 2 * 1024 * 1024 * 1024 else {
                throw VaultError.server("Too big: the vault takes files up to 2 GB.")
            }
            var ticket: VaultAPI.UploadTicket
            var resumed: VaultAPI.UploadTicket?
            if let existing = job.uploadID {
                do {
                    resumed = try await api.uploadState(existing)
                } catch VaultError.http(404, _) {
                    resumed = nil   // the server forgot it (finished, or purged): start over
                }
            }
            if let resumed {
                ticket = resumed
            } else {
                var fields: [String: Any] = ["parent_id": job.parentID, "kind": info.kind.rawValue,
                                             "filename": job.filename, "mime": info.mime, "size": info.size,
                                             "title": (job.filename as NSString).deletingPathExtension]
                if let d = info.duration { fields["duration_s"] = d }
                if let w = info.width { fields["width"] = w }
                if let h = info.height { fields["height"] = h }
                if let p = info.pages { fields["pages"] = p }
                ticket = try await api.startUpload(fields)
                if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].uploadID = ticket.id }
            }
            let handle = try FileHandle(forReadingFrom: job.file)
            defer { try? handle.close() }
            let chunk = max(1, ticket.chunkSize)
            let count = max(1, Int((info.size + Int64(chunk) - 1) / Int64(chunk)))
            for index in 0..<count {
                if ticket.received.contains(index) {
                    setProgress(job.id, Double(index + 1) / Double(count))
                    continue
                }
                try handle.seek(toOffset: UInt64(index) * UInt64(chunk))
                let data = try handle.read(upToCount: chunk) ?? Data()
                try await withRetries { try await self.api.putChunk(ticket.id, index: index, data: data) }
                setProgress(job.id, Double(index + 1) / Double(count) * 0.98)
            }
            if let thumb = info.thumbJPEG {
                try? await withRetries { try await self.api.putThumb(ticket.id, jpeg: thumb) }
            }
            try await withRetries { try await self.api.finishUpload(ticket.id) }
            return .success(ticket.id)
        } catch {
            return .failure(error)
        }
    }

    private func withRetries(_ body: @escaping () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do { return try await body() } catch {
                attempt += 1
                let transient = (error as? VaultError)?.isTransient ?? !(error is VaultError)
                if attempt >= 4 || !transient { throw error }
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }
}

/// The capsule over a vault screen while uploads run.
struct VaultUploadsBar: View {
    @ObservedObject var uploads: VaultUploads

    var body: some View {
        if let summary = uploads.summary {
            HStack(spacing: 10) {
                if uploads.active.contains(where: { $0.failed == nil }) {
                    JcLoader(size: 16).foregroundStyle(JcTheme.text)
                } else {
                    JcIcon("exclamationmark.triangle", size: 14).foregroundStyle(JcTheme.amber)
                }
                Text(summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .monospacedDigit()
                if uploads.active.contains(where: { $0.failed != nil }) {
                    Button("Retry") { uploads.retryFailed() }
                        .buttonStyle(.jcGlass(tint: JcTheme.text, compact: true))
                    Button("Discard") { uploads.discardFailed() }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .jcLiquidGlass(in: Capsule())
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
