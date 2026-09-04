import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The phone's OWN speech synthesizer — `AVSpeechSynthesizer` on iOS,
/// `TextToSpeech` on Android (plan 4.4).
///
/// This is not the JARVIS voice: it's the sub-100 ms one. It exists so a local
/// action can be acknowledged out loud ("On it", "Flashlight on") without a
/// network round-trip to `/api/voice/synthesize`, which is the whole point of
/// Lane 0 — the reply must land while the user's finger is still off the
/// button. Server TTS remains the voice for actual replies.
///
/// Everything degrades silently: no bridge (older build, unsupported platform)
/// means [speak] returns false and the caller falls back to text / server TTS.
class LocalTts {
  LocalTts._();

  static const MethodChannel _channel =
      MethodChannel('jarviscopilot/local_tts');

  /// Latched after a MissingPluginException so we don't pay a channel
  /// round-trip per ack on a build without the native side.
  static bool _unsupported = false;

  static bool get available => !_unsupported;

  /// Speak [text] on this device immediately. Returns true when the platform
  /// accepted it. Interrupts anything the local synthesizer is already saying —
  /// an ack is only ever about the turn happening right now.
  static Future<bool> speak(String text, {double rate = 0.52}) async {
    final t = text.trim();
    if (t.isEmpty || _unsupported) return false;
    try {
      final ok = await _channel.invokeMethod('speak', {
        'text': t,
        'rate': rate,
      });
      return ok == true;
    } on MissingPluginException {
      _unsupported = true;
      return false;
    } catch (e) {
      debugPrint('[local-tts] speak failed: $e');
      return false;
    }
  }

  /// Stop mid-ack (barge-in, new turn).
  static Future<void> stop() async {
    if (_unsupported) return;
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      _unsupported = true;
    } catch (_) {}
  }
}
