import 'dart:ui';

/// Voice session finite-state machine — mirrors the webui voice FSM.
enum VoiceState { idle, connecting, listening, thinking, speaking, error }

/// Conversation mode. Quality is one-shot push-to-talk over the
/// NDJSON `/api/voice/quality-turn` endpoint; realtime is a continuous
/// streaming session over the `/api/voice/s2s/ws` WebSocket.
enum VoiceMode { quality, realtime }

extension VoiceStateLabel on VoiceState {
  String get label {
    switch (this) {
      case VoiceState.idle:
        return 'Idle';
      case VoiceState.connecting:
        return 'Connecting';
      case VoiceState.listening:
        return 'Listening';
      case VoiceState.thinking:
        return 'Thinking';
      case VoiceState.speaking:
        return 'Speaking';
      case VoiceState.error:
        return 'Error';
    }
  }

  /// [inner, mid, outer, rim] palette per state, matching voice.js.
  List<Color> get palette {
    switch (this) {
      case VoiceState.idle:
        return const [
          Color(0xFFCFE8FF),
          Color(0xFF8A7CFF),
          Color(0xFF12162E),
          Color(0xFFA9C2FF),
        ];
      // Iridescent family — [inner, mid, outer, rim].
      case VoiceState.connecting:
        return const [
          Color(0xFFCBA8FF),
          Color(0xFF8A7CFF),
          Color(0xFF1A1340),
          Color(0xFFB9A8FF),
        ];
      case VoiceState.listening:
        return const [
          Color(0xFFAFF6F0),
          Color(0xFF46E0E0),
          Color(0xFF0B2E36),
          Color(0xFF8FE8FF),
        ];
      case VoiceState.thinking:
        return const [
          Color(0xFFD8C2FF),
          Color(0xFF8A7CFF),
          Color(0xFF1A1340),
          Color(0xFFCBB6FF),
        ];
      case VoiceState.speaking:
        return const [
          Color(0xFFFFC2EC),
          Color(0xFFFF6FD8),
          Color(0xFF3A0E2E),
          Color(0xFFFFB0E4),
        ];
      case VoiceState.error:
        return const [
          Color(0xFFFFB0BA),
          Color(0xFFFF6B7E),
          Color(0xFF4A0A12),
          Color(0xFFFF9AA6),
        ];
    }
  }
}
