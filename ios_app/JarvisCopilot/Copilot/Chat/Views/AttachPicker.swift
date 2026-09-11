import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where a composer's "+" delivers what the user picked.
@MainActor
protocol AttachmentSink: AnyObject {
    func addAttachment(_ attachment: PendingAttachment)
    /// Why the last pick couldn't be used, for the composer to show.
    var attachError: String? { get set }
}

extension ChatStore: AttachmentSink {}

/// The composer's "+" — camera, photo library and files — shared by the Chat and
/// Coding composers.
///
/// Each source is a system affordance, so the button owns all three presentations
/// and hands finished ``PendingAttachment``s to its sink. Picking is a *view*
/// concern (the stores never touch PhotosUI), which is why the loading lives here —
/// including the size gate and the off-main read.
struct AttachControl: View {
    let sink: any AttachmentSink
    var enabled = true
    /// Library videos, each with a first-frame poster for the model. The Coding
    /// composer hands files to a terminal agent that can't watch a movie, so it
    /// turns this off.
    var allowsVideo = true

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            if ChatCameraPicker.isAvailable {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { showPhotos = true } label: {
                Label(allowsVideo ? "Photo or video" : "Photo", systemImage: "photo.on.rectangle")
            }
            Button { showFiles = true } label: { Label("File", systemImage: "doc") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(enabled ? JcTheme.text : JcTheme.muted.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(allowsVideo ? "Attach photo, video, or file" : "Attach photo or file")
        .photosPicker(isPresented: $showPhotos, selection: $picked,
                      maxSelectionCount: 4, matching: allowsVideo ? .any(of: [.images, .videos]) : .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await load(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await load(files: urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ChatCameraPicker { image in
                // The picker itself never dismisses: the flag that presented it
                // is the only thing that can, and a cancel must clear it too.
                showCamera = false
                guard let data = image?.jpegData(compressionQuality: 0.85) else { return }
                sink.addAttachment(PendingAttachment(
                    name: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                    data: data, isImage: true))
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Loading

    @MainActor private func load(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            let isVideo = allowsVideo && item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                sink.attachError = "Could not read that item."
                continue
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension
                ?? (isVideo ? "mov" : "jpg")
            let name = "\(isVideo ? "video" : "photo")-\(Int(Date().timeIntervalSince1970))-\(offset).\(ext)"
            await add(name: name, data: data, isVideo: isVideo)
        }
    }

    /// Files are gated on their *length* and then read off the main actor: a
    /// synchronous `Data(contentsOf:)` on a large iCloud-backed file blocks the
    /// composer for as long as the download takes, and reading it at all before
    /// the size check is how a huge pick runs the app out of memory
    /// (swift-correctness H14).
    @MainActor private func load(files urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let isVideo = allowsVideo && PendingAttachment.looksLikeVideo(url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let size, let rejection = PendingAttachment.rejection(bytes: size, isVideo: isVideo) {
                sink.attachError = rejection
                continue
            }
            let read = await Task.detached(priority: .userInitiated) { () -> Data? in
                do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
                    JcLog.dropped(JcLog.chat, "read picked file", error)
                    return nil
                }
            }.value
            guard let data = read, !data.isEmpty else {
                sink.attachError = "Could not read \(url.lastPathComponent)."
                continue
            }
            // `fileSize` is missing for some providers; the length we actually read
            // is the last word.
            if let rejection = PendingAttachment.rejection(bytes: data.count, isVideo: isVideo) {
                sink.attachError = rejection
                continue
            }
            await add(name: url.lastPathComponent, data: data, isVideo: isVideo)
        }
    }

    /// A video is uploaded whole, so the size gate runs before the bytes are ever
    /// queued — `PendingAttachment.videoRejection` owns that rule.
    ///
    /// Decoding the poster frame is done off the main actor: a long clip's first
    /// frame takes long enough to drop the composer's typing animation.
    @MainActor private func add(name: String, data: Data, isVideo: Bool) async {
        if isVideo, let rejection = PendingAttachment.videoRejection(bytes: data.count) {
            sink.attachError = rejection
            return
        }
        var poster: Data?
        if isVideo {
            let ext = (name as NSString).pathExtension
            poster = await Task.detached(priority: .userInitiated) {
                ChatVideoPoster.firstFrame(of: data, extension: ext)
            }.value
        }
        sink.addAttachment(PendingAttachment(
            name: name,
            data: data,
            isImage: !isVideo && PendingAttachment.looksLikeImage(name),
            isVideo: isVideo,
            posterData: poster))
    }
}

/// A video's first frame as JPEG. The model can look at a frame but not at a
/// movie, so the poster is uploaded alongside the file as a vision image (see
/// ``uploadChatAttachments``).
enum ChatVideoPoster {
    static func firstFrame(of data: Data, extension ext: String) -> Data? {
        // AVFoundation reads files, not buffers, so the picked bytes land in a
        // temp file first. It is deleted before we return.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        do { try data.write(to: url) } catch {
            JcLog.dropped(JcLog.chat, "stage video for poster frame", error)
            return nil
        }
        defer {
            // Leaving the clip behind costs the user real disk (silent-failures L5).
            do { try FileManager.default.removeItem(at: url) } catch {
                JcLog.dropped(JcLog.chat, "remove staged video", error)
            }
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_024, height: 1_024)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
    }
}

/// `UIImagePickerController` in camera mode. SwiftUI has no camera control of its
/// own, and `PhotosPicker` only reads the library.
///
/// `onPick` is called exactly once — with the image, or with nil on cancel — and
/// the caller is responsible for taking the presentation down, so a cancel can
/// never strand the sheet.
struct ChatCameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = Self.isAvailable ? .camera : .photoLibrary
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
