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
          Color(0xFFCFD9FF),
          Color(0xFF6080FF),
          Color(0xFF10204A),
          Color(0xFFA9BCFF),
        ];
      case VoiceState.connecting:
        return const [
          Color(0xFFE0C2FF),
          Color(0xFFA263FF),
          Color(0xFF3A1080),
          Color(0xFFCDA1FF),
        ];
      case VoiceState.listening:
        return const [
          Color(0xFF9CE8FF),
          Color(0xFF3AA7FF),
          Color(0xFF1147B8),
          Color(0xFF9CE8FF),
        ];
      case VoiceState.thinking:
        return const [
          Color(0xFFE0C2FF),
          Color(0xFFA263FF),
          Color(0xFF3A1080),
          Color(0xFFCDA1FF),
        ];
      case VoiceState.speaking:
        return const [
          Color(0xFFFFD9A8),
          Color(0xFFFF8A3A),
          Color(0xFF7A2D00),
          Color(0xFFFFD9A8),
        ];
      case VoiceState.error:
        return const [
          Color(0xFFFF9090),
          Color(0xFFFF3030),
          Color(0xFF6E0000),
          Color(0xFFFF8080),
        ];
    }
  }
}
