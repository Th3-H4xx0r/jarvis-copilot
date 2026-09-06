import Foundation

/// A composer attachment the user picked but hasn't sent yet.
/// Ported from `widgets/composer_attach.dart`'s `PendingAttachment`.
///
/// `Copilot/Coding` has its own narrower `PendingAttachment` (no video/poster, and
/// it uploads to the session host instead of `/api/upload`). Flutter shares one
/// type between the two composers; unifying them is a follow-up for whoever owns
/// the shared composer UI — this one is the superset.
struct ChatPendingAttachment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var data: Data
    var isImage = false
    /// True for a video: on send the file is uploaded AND ``posterData`` (a
    /// first-frame JPEG) is uploaded separately as a vision image, because the
    /// model can look at the frame but not at the movie.
    var isVideo = false
    var posterData: Data?

    var size: Int { data.count }

    /// Bytes to show in the composer chip and the sent bubble: an image previews
    /// with itself, a video with its poster, and a plain file not at all.
    var thumbnail: Data? {
        if isImage { return data }
        if isVideo { return posterData }
        return nil
    }

    var messageAttachment: MessageAttachment {
        MessageAttachment(name: name, thumbnail: thumbnail)
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
    _ pending: [ChatPendingAttachment],
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
