import SwiftUI

/// Voice session finite-state machine — mirrors the webui voice FSM
/// (`voice/voice_state.dart`).
enum VoiceState: String, CaseIterable, Sendable {
    case idle, connecting, listening, thinking, speaking, error

    /// True while a session is running (`active` in the Flutter controller).
    var isActive: Bool { self != .idle && self != .error }
}

/// Conversation mode. Quality is one-shot push-to-talk over the NDJSON
/// `/api/voice/quality-turn` endpoint; realtime is a continuous streaming
/// session over the `/api/voice/s2s/ws` WebSocket.
enum VoiceMode: String, CaseIterable, Sendable {
    case quality, realtime

    var label: String { self == .quality ? "Push to talk" : "Realtime" }
}
