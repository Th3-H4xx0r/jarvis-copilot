import UIKit
import UniformTypeIdentifiers

/// Paste-to-attach for the chat composer, the way ChatGPT does it: Paste with a
/// copied image or file puts it in the attachment strip; Paste with copied text
/// still pastes the text.
enum PasteboardAttachments {
    /// Whether the clipboard *might* hold something to attach, from its type
    /// identifiers alone. The edit menu asks this before every display, so it
    /// must not read the clipboard's contents — that would raise the "Allow
    /// Paste" prompt just for long-pressing the field.
    static func mayAttach(types: [String]) -> Bool {
        types.compactMap { UTType($0) }.contains(where: isAttachable)
    }

    /// The providers a paste should attach, or none to paste text normally.
    ///
    /// Real text wins: Notes and Mail put a picture beside the words, and the
    /// user meant the words. Text that is only a link (Safari's "Copy" on an
    /// image) or only a copied file's name is not real text.
    static func attachable(_ providers: [NSItemProvider], text: String?) -> [NSItemProvider] {
        let candidates = providers.filter { $0.registeredContentTypes.contains(where: isAttachable) }
        let names = Set(candidates.compactMap(\.suggestedName))
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLink = URL(string: trimmed)?.scheme.map { ["http", "https"].contains($0) } ?? false
        if !trimmed.isEmpty, !isLink, !names.contains(trimmed) { return [] }
        let images = candidates.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        return images.isEmpty ? candidates : images
    }

    /// Read each provider and hand it to the sink like a "+" pick: same size cap,
    /// same video poster. A failed item is named in the sink's error line; the
    /// rest still attach.
    @MainActor static func add(_ providers: [NSItemProvider], to sink: any AttachmentSink) async {
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        for (offset, provider) in providers.enumerated() {
            do {
                let item = try await read(provider, name: "pasted-\(stamp)-\(offset)")
                await sink.addPicked(name: item.name, data: item.data, isVideo: item.isVideo)
            } catch let error as PasteError {
                sink.attachError = error.message
            } catch {
                JcLog.dropped(JcLog.chat, "read pasted item", error)
                sink.attachError = "Could not paste that item."
            }
        }
    }

    struct Item: Equatable {
        var name: String
        var data: Data
        var isVideo: Bool
    }

    struct PasteError: Error { let message: String }

    /// An image comes back as PNG/JPEG/GIF/WebP — anything else (HEIC from
    /// Photos, TIFF) is re-encoded as JPEG, because the server only shows the
    /// model formats it recognises. A file keeps its own name.
    static func read(_ provider: NSItemProvider, name: String) async throws -> Item {
        let types = provider.registeredContentTypes
        if let type = types.first(where: { $0.conforms(to: .image) }) {
            let data = try await provider.data(for: type)
            if let rejection = PendingAttachment.rejection(bytes: data.count, isVideo: false) {
                throw PasteError(message: rejection)
            }
            if let ext = webImageExtension(type) {
                return Item(name: "\(name).\(ext)", data: data, isVideo: false)
            }
            guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else {
                throw PasteError(message: "Could not read that image.")
            }
            return Item(name: "\(name).jpg", data: jpeg, isVideo: false)
        }
        guard let type = types.first(where: isAttachable) else {
            throw PasteError(message: "Could not paste that item.")
        }
        let (fileName, data) = try await provider.file(for: type)
        var named = provider.suggestedName ?? fileName
        if let ext = type.preferredFilenameExtension, (named as NSString).pathExtension.isEmpty {
            named += ".\(ext)"
        }
        return Item(name: named, data: data, isVideo: type.conforms(to: .movie))
    }

    /// Anything with bytes that isn't text or a link: images, PDFs, movies, documents.
    private static func isAttachable(_ type: UTType) -> Bool {
        (type.conforms(to: .data) || type.conforms(to: .package))
            && !type.conforms(to: .text) && !type.conforms(to: .url) && !type.isDynamic
    }

    private static func webImageExtension(_ type: UTType) -> String? {
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .gif) { return "gif" }
        if type.conforms(to: .webP) { return "webp" }
        return nil
    }
}

private extension NSItemProvider {
    func data(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error
                        ?? PasteboardAttachments.PasteError(message: "Could not read that image."))
                }
            }
        }
    }

    /// The provider's temp file only lives inside the callback, so the size gate
    /// and the read both happen there — the gate first, so a huge copied file is
    /// never pulled into memory (same rule as the "+" file picker).
    func file(for type: UTType) async throws -> (String, Data) {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error
                        ?? PasteboardAttachments.PasteError(message: "Could not paste that file."))
                    return
                }
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                   let rejection = PendingAttachment.rejection(bytes: size, isVideo: type.conforms(to: .movie)) {
                    continuation.resume(throwing: PasteboardAttachments.PasteError(message: rejection))
                    return
                }
                do {
                    continuation.resume(returning: (url.lastPathComponent, try Data(contentsOf: url)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
