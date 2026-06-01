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
      // Ref-blue family for the glass orb — bright cyan/blue ribbons with a
      // violet accent. [inner=highlight, mid=core, outer=dark, rim=accent].
      case VoiceState.idle:
        return const [
          Color(0xFF8FD8FF),
          Color(0xFF3A86FF),
          Color(0xFF0A1430),
          Color(0xFF7C5CFF),
        ];
      case VoiceState.connecting:
        return const [
          Color(0xFF9FC2FF),
          Color(0xFF5C7CFF),
          Color(0xFF0A1230),
          Color(0xFF8C6CFF),
        ];
      case VoiceState.listening:
        return const [
          Color(0xFFAFF0FF),
          Color(0xFF2FB8FF),
          Color(0xFF071A2E),
          Color(0xFF6FD0FF),
        ];
      case VoiceState.thinking:
        return const [
          Color(0xFFBFA8FF),
          Color(0xFF6A5CFF),
          Color(0xFF0E0E2E),
          Color(0xFF9C8CFF),
        ];
      case VoiceState.speaking:
        return const [
          Color(0xFF9FE0FF),
          Color(0xFF3A86FF),
          Color(0xFF081634),
          Color(0xFF7C5CFF),
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
