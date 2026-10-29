import QuickLook
import SwiftUI

/// The built-in viewer for a chat attachment: QuickLook, so a PDF pages, a text
/// file scrolls, an image zooms and an Office document renders, with the
/// system's share button. Takes the bytes (local for an unsent or just-sent
/// attachment, fetched for a reloaded one) and shows them from a temp copy that
/// is deleted when the viewer closes.
struct AttachmentViewer: UIViewControllerRepresentable {
    let name: String
    let data: Data
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(name: name, data: data) }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        coordinator.cleanUp()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-view-\(UUID().uuidString)", isDirectory: true)
        private let file: URL?

        init(name: String, data: Data) {
            let url = directory.appendingPathComponent(ChatFilePreview.safeName(name))
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                file = url
            } catch {
                JcLog.dropped(JcLog.chat, "stage attachment for viewer", error)
                file = nil
            }
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (file ?? directory) as NSURL
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

extension View {
    /// Present ``AttachmentViewer`` full screen while `item` is set.
    func attachmentViewer(_ item: Binding<ViewedAttachment?>) -> some View {
        fullScreenCover(item: item) { viewed in
            AttachmentViewer(name: viewed.name, data: viewed.data) { item.wrappedValue = nil }
                .ignoresSafeArea()
        }
    }
}

/// What the viewer is showing.
struct ViewedAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}
