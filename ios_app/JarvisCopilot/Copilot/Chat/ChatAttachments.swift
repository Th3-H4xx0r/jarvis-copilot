import Foundation

/// A composer attachment the user picked but hasn't sent yet. The Chat composer
/// uploads it to `/api/upload`; the Coding composer to the session's host.
struct PendingAttachment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var data: Data
    var isImage = false
    /// True for a video: on send the file is uploaded AND ``posterData`` (a
    /// first-frame JPEG) is uploaded separately as a vision image, because the
    /// model can look at the frame but not at the movie.
    var isVideo = false
    var posterData: Data?
    /// A small drawn preview (``ChatFilePreview``): a PDF's first page, a text
    /// file's opening lines, a downsized photo.
    var previewData: Data?

    var size: Int { data.count }

    /// Bytes to show in the composer tile and the sent bubble: the drawn preview,
    /// else an image's own bytes or a video's poster; nil shows the file's glyph.
    var thumbnail: Data? {
        if let previewData { return previewData }
        if isImage { return data }
        if isVideo { return posterData }
        return nil
    }

    /// The sent bubble keeps the bytes so the viewer opens them without a
    /// round trip — except a movie, too big to hold per message.
    var messageAttachment: MessageAttachment {
        MessageAttachment(name: name, thumbnail: thumbnail, data: isVideo ? nil : data)
    }

    static func looksLikeImage(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains { lower.hasSuffix($0) }
    }

    /// A video is uploaded whole, so a multi-GB pick would run the app out of
    /// memory. The Flutter composer checks the file length *before* reading the
    /// bytes and caps it here; the picker must do the same.
    static let maxVideoBytes = 100 * 1024 * 1024

    /// nil when a picked video is acceptable, else the line for ``ChatStore/attachError``.
    static func videoRejection(bytes: Int) -> String? {
        rejection(bytes: bytes, isVideo: true)
    }

    /// The same cap for every pick, not just videos: the composer holds the whole
    /// file in memory, so a multi-gigabyte document is just as fatal as a movie.
    /// Checked against the file's *length* before the bytes are read
    /// (swift-correctness H14).
    static func rejection(bytes: Int, isVideo: Bool) -> String? {
        guard bytes > maxVideoBytes else { return nil }
        return isVideo ? "That video is too large (max 100 MB)."
                       : "That file is too large (max 100 MB)."
    }

    /// Extensions the picker treats as movies.
    static func looksLikeVideo(_ name: String) -> Bool {
        ["mov", "mp4", "m4v", "avi", "webm"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// Upload each pending attachment (and a video's first-frame poster as a second
/// vision image), returning the result maps for `/api/chat/start`'s
/// `attachments[]`.
///
/// A failed upload is skipped so the rest — and the message text — still send,
/// but the caller is told how many were dropped: a message that silently goes out
/// without the photo it was about is worse than a warning
/// (silent-failures H3).
/// Free function with an injected `upload` so it is testable without a store.
@discardableResult
func uploadChatAttachments(
    _ pending: [PendingAttachment],
    upload: (_ name: String, _ data: Data) async throws -> [String: Any]
) async -> (uploads: [[String: Any]], failed: [String]) {
    var out: [[String: Any]] = []
    var failed: [String] = []
    for attachment in pending {
        do {
            let result = try await upload(attachment.name, attachment.data)
            if result.isEmpty { failed.append(attachment.name); continue }
            out.append(result)
            if let poster = attachment.posterData, !poster.isEmpty {
                // A missing poster costs the model its look at the clip, but the
                // file itself did land — not worth failing the attachment over.
                if let posterResult = try? await upload("\(attachment.name).poster.jpg", poster),
                   !posterResult.isEmpty {
                    out.append(posterResult)
                }
            }
        } catch {
            // Skip this attachment; keep the others and the message text.
            JcLog.dropped(JcLog.chat, "attachment upload", error)
            failed.append(attachment.name)
        }
    }
    return (out, failed)
}

/// The composer line for attachments that never made it to the server.
func chatAttachmentFailureMessage(_ failed: [String]) -> String? {
    guard !failed.isEmpty else { return nil }
    if failed.count == 1 { return "Couldn't upload \(failed[0]) — it was left out of this message." }
    return "Couldn't upload \(failed.count) attachments — they were left out of this message."
}

/// The server shows the model an uploaded *image* itself, but leaves every other
/// file for the agent to open by path — and only the message text carries that
/// path. Same line the web client adds (`messages.js`), so the server's own
/// bookkeeping (it splits on this marker) treats both alike.
enum ChatFileRefs {
    private static let marker = "[Attached files: "

    static func messageText(_ text: String, uploads: [[String: Any]]) -> String {
        let paths = uploads.compactMap { upload -> String? in
            guard upload["is_image"] as? Bool != true else { return nil }
            return upload["path"] as? String ?? upload["filename"] as? String
        }
        guard !paths.isEmpty else { return text }
        let line = marker + paths.joined(separator: ", ") + "]"
        return text.isEmpty ? line : "\(text)\n\n\(line)"
    }

    /// The text as the user wrote it: the path line is for the model, not the bubble.
    static func stripped(_ text: String) -> String {
        if text.hasPrefix(marker) { return "" }
        guard let range = text.range(of: "\n\n" + marker) else { return text }
        return String(text[..<range.lowerBound])
    }
}
