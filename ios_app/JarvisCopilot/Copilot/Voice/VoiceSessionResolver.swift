import Foundation

/// Resolves the voice session, for every surface that speaks.
///
/// The phone's voice transport and the Apple Watch both need the SAME answer —
/// the session the Voice tab's picker points at, or the server's dedicated
/// "Voice" chat. Extracted so there is one implementation: a watch turn lands in
/// the same conversation, with the same history and model binding, as if you had
/// spoken to the phone.
@MainActor
final class VoiceSessionResolver {
    static let shared = VoiceSessionResolver()

    private var sessionID: String?
    private var boundTarget: VoiceSessionSelection.Target?

    /// Forget the cached id, so the next turn resolves afresh.
    func invalidate() {
        sessionID = nil
        boundTarget = nil
    }

    /// The server's dedicated, persistent "Voice" chat — NOT whatever session is
    /// most-recent. Grabbing the newest session used to land voice on a
    /// coding/CLI channel wired to a provider+model it couldn't use, which then
    /// failed silently.
    func ensureSession(voice: VoiceAPI, note: ((String) -> Void)? = nil) async throws -> String {
        let target = VoiceSessionSelection.shared.target
        if let sessionID, !sessionID.isEmpty, boundTarget == target { return sessionID }
        boundTarget = target
        // A session picked in the voice session picker (or created from it).
        // Verify it still exists; a deleted one falls back to the default.
        if let picked = target.sessionID, !picked.isEmpty {
            if (try? await SessionsAPI(api: voice.api).get(picked)) != nil {
                sessionID = picked
                return picked
            }
            note?("picked voice session missing; using default")
            VoiceSessionSelection.shared.select(.defaultVoice)
        }
        do {
            let id = try await voice.voiceSessionID()
            if !id.isEmpty {
                sessionID = id
                return id
            }
        } catch {
            // Older servers have no /api/voice/session; fall through and create
            // a plain chat instead.
            JcLog.dropped(JcLog.voice, "resolve voice session", error)
        }
        let created = try await voice.api.post("/api/session/new",
                                               json: ["title": "Voice"]).object()
        let session = created.dict("session") ?? created
        let id = session.string("session_id") ?? ""
        guard !id.isEmpty else { throw APIError.badResponse("could not create a voice session") }
        sessionID = id
        return id
    }
}
