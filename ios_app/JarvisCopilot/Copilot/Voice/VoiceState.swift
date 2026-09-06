import SwiftUI

/// Voice session finite-state machine — mirrors the webui voice FSM
/// (`voice/voice_state.dart`).
enum VoiceState: String, CaseIterable, Sendable {
    case idle, connecting, listening, thinking, speaking, error

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error: return "Error"
        }
    }

    /// `[inner, mid, outer, rim]` per state, matching voice.js. Ref-blue family
    /// for the glass orb — bright cyan/blue ribbons with a violet accent
    /// (inner = highlight, mid = core, outer = dark, rim = accent).
    var palette: [Color] {
        switch self {
        case .idle:       return [rgb(0x9FDBFF), rgb(0x2F6BFF), rgb(0x061033), rgb(0x4B7CFF)]
        case .connecting: return [rgb(0x9FC2FF), rgb(0x5C7CFF), rgb(0x0A1230), rgb(0x8C6CFF)]
        case .listening:  return [rgb(0xAFF0FF), rgb(0x2FB8FF), rgb(0x071A2E), rgb(0x6FD0FF)]
        case .thinking:   return [rgb(0xBFA8FF), rgb(0x6A5CFF), rgb(0x0E0E2E), rgb(0x9C8CFF)]
        case .speaking:   return [rgb(0xA8E4FF), rgb(0x2F6BFF), rgb(0x061033), rgb(0x4B7CFF)]
        case .error:      return [rgb(0xFFB0BA), rgb(0xFF6B7E), rgb(0x4A0A12), rgb(0xFF9AA6)]
        }
    }

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

/// Local so no other area's `Color(hex:)` extension can collide with it.
private func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255,
          opacity: 1)
}
