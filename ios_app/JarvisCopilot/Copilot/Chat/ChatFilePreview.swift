import QuickLookThumbnailing
import UIKit

/// Previews for chat attachments, the way Claude shows them: a picture for an
/// image, the first page for a PDF, the opening lines for a text file — whatever
/// QuickLook can draw — and the bytes behind a sent attachment, fetched back
/// from the server after a reload (it only remembers the name).
enum ChatFilePreview {
    /// Long side of a preview, in pixels: sharp on the 160-pt bubble tile at 3×
    /// without holding a full-resolution photo per row.
    static let pixels: CGFloat = 480

    /// A JPEG preview of `data`, or nil when nothing can draw it (the tile then
    /// shows the file's glyph and type).
    static func thumbnail(of data: Data, name: String) async -> Data? {
        if PendingAttachment.looksLikeImage(name) || UIImage(data: data) != nil {
            return downsampled(data)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-preview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(safeName(name))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            JcLog.dropped(JcLog.chat, "stage attachment for preview", error)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pixels / 3, height: pixels / 3), scale: 3,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        return rep.uiImage.jpegData(compressionQuality: 0.8)
    }

    /// Where the server keeps a sent attachment: this chat's uploads, by the name
    /// it stored (the same URL the web chat uses), root-relative for
    /// ``ChatImageCache``.
    static func source(sessionID: String, name: String) -> String {
        "/api/file/raw?session_id=\(encode(sessionID))&path=\(encode(name))"
    }

    /// Too big to pull down just for a tile.
    static func skipsRemotePreview(_ name: String) -> Bool { PendingAttachment.looksLikeVideo(name) }

    private static func downsampled(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > pixels else { return image.jpegData(compressionQuality: 0.8) }
        let factor = pixels / longest
        let size = CGSize(width: image.size.width * image.scale * factor,
                          height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// A name that is safe as one path component, keeping its extension (which is
    /// how QuickLook picks a renderer).
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file\(cleaned)" : cleaned
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
