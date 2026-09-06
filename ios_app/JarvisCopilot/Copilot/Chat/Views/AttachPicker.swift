import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer's "+" — camera, photo/video library, and files — ported from
/// `widgets/composer_attach.dart`.
///
/// Flutter has one plugin per source; here each is a system affordance, so the
/// button owns all three presentations and hands finished
/// ``ChatPendingAttachment``s to the store. Picking is a *view* concern (the
/// store never touches PhotosUI), which is why the async loading lives here.
struct ChatAttachControl: View {
    let store: ChatStore
    var enabled = true

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
                Label("Photo or video", systemImage: "photo.on.rectangle")
            }
            Button { showFiles = true } label: { Label("File", systemImage: "doc") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(JcTheme.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel("Attach photo, video, or file")
        .photosPicker(isPresented: $showPhotos, selection: $picked,
                      maxSelectionCount: 4, matching: .any(of: [.images, .videos]))
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
                store.addAttachment(ChatPendingAttachment(
                    name: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                    data: data, isImage: true))
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Loading

    @MainActor private func load(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                store.attachError = "Could not read that item."
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

            let isVideo = ChatPendingAttachment.looksLikeVideo(url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let size, let rejection = ChatPendingAttachment.rejection(bytes: size, isVideo: isVideo) {
                store.attachError = rejection
                continue
            }
            let read = await Task.detached(priority: .userInitiated) { () -> Data? in
                do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
                    JcLog.dropped(JcLog.chat, "read picked file", error)
                    return nil
                }
            }.value
            guard let data = read, !data.isEmpty else {
                store.attachError = "Could not read \(url.lastPathComponent)."
                continue
            }
            // `fileSize` is missing for some providers; the length we actually read
            // is the last word.
            if let rejection = ChatPendingAttachment.rejection(bytes: data.count, isVideo: isVideo) {
                store.attachError = rejection
                continue
            }
            await add(name: url.lastPathComponent, data: data, isVideo: isVideo)
        }
    }

    /// A video is uploaded whole, so the size gate runs before the bytes are ever
    /// queued — `ChatPendingAttachment.videoRejection` owns that rule.
    ///
    /// Decoding the poster frame is done off the main actor: a long clip's first
    /// frame takes long enough to drop the composer's typing animation.
    @MainActor private func add(name: String, data: Data, isVideo: Bool) async {
        if isVideo, let rejection = ChatPendingAttachment.videoRejection(bytes: data.count) {
            store.attachError = rejection
            return
        }
        var poster: Data?
        if isVideo {
            let ext = (name as NSString).pathExtension
            poster = await Task.detached(priority: .userInitiated) {
                ChatVideoPoster.firstFrame(of: data, extension: ext)
            }.value
        }
        store.addAttachment(ChatPendingAttachment(
            name: name,
            data: data,
            isImage: !isVideo && ChatPendingAttachment.looksLikeImage(name),
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
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
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
#endif
