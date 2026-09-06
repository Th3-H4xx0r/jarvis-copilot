import Foundation
import Observation

/// The composer's picked-but-unsent attachments, shared by the terminal composer
/// and the chat input bar (port of the attachment half of
/// `coding/coding_controller.dart` + `coding/coding_attach.dart`).
///
/// Picking is a *view* concern on iOS — SwiftUI presents `PhotosPicker` /
/// `.fileImporter` / the camera and hands the bytes to `add`, where Flutter
/// called into image_picker/file_picker from the controller. Everything after
/// the pick (the upload and the `@path` folding) lives here.
@Observable @MainActor
final class CodingAttachments {
    private let api: CodingSessionsAPI

    init(api: CodingSessionsAPI = CodingSessionsAPI()) { self.api = api }

    /// Photos/files the user picked but hasn't sent yet (rendered as chips).
    private(set) var items: [PendingAttachment] = []

    /// Set when one or more uploads failed, so the composer can warn instead of
    /// silently dropping the file.
    var error: String?

    var isEmpty: Bool { items.isEmpty }

    func add(_ attachment: PendingAttachment) { items.append(attachment) }

    func add(name: String, data: Data, isImage: Bool? = nil) {
        // Flutter took `x.name.split('/').last` because the pickers hand back
        // paths on some platforms.
        let base = CodingJSON.basename(name)
        items.append(PendingAttachment(name: base.isEmpty ? name : base,
                                       data: data, isImage: isImage))
    }

    func remove(_ attachment: PendingAttachment) { items.removeAll { $0.id == attachment.id } }

    func clear() { items.removeAll() }

    /// Upload every pending attachment for `sessionId` and fold their `@path`
    /// references into `text`; clears the pending list either way.
    ///
    /// Returns the combined message text plus how many attachments FAILED, so the
    /// caller can warn the user. Paths are space-joined — never newlines, since a
    /// newline submits the TUI input early.
    func consume(into text: String, sessionId: String) async -> (text: String, failed: Int) {
        // Clear last time's warning first — a send with nothing attached must not
        // resurface a previous failure.
        error = nil
        guard !items.isEmpty, !sessionId.isEmpty else { return (text, 0) }
        let pending = items
        var refs: [String] = []
        var failed = 0
        for a in pending {
            do {
                if let path = try await api.uploadFile(sessionId, data: a.data, filename: a.name),
                   !path.isEmpty {
                    refs.append("@\(path)")
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        clear()
        error = Self.failureMessage(failed: failed, of: pending.count)
        guard !refs.isEmpty else { return (text, failed) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = refs.joined(separator: " ")
        return (body.isEmpty ? joined : "\(body) \(joined)", failed)
    }

    static func failureMessage(failed: Int, of total: Int) -> String? {
        guard failed > 0 else { return nil }
        return failed == total
            ? "Attachments failed to upload"
            : "\(failed) attachment(s) failed to upload"
    }
}
