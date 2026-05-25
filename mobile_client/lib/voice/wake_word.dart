import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Foreground "Hey Jarvis" wake-word listener built on on-device speech
/// recognition (Apple Speech on iOS).
///
/// Experimental and deliberately constrained by iOS: there is no
/// background/always-on custom wake word for third-party apps, so this
/// only runs while the Voice screen is open and the assistant is idle.
/// The mic can't be shared, so the listener must be fully stopped before
/// a recording turn starts (the page handles that handoff). Continuous
/// recognition is battery-heavy, hence opt-in and off by default.
class WakeWordListener {
  WakeWordListener({required this.onWake, this.phrase = 'jarvis'});

  /// Fired once when [phrase] is heard. The listener stops itself first.
  final VoidCallback onWake;
  final String phrase;

  final SpeechToText _stt = SpeechToText();
  bool _available = false;
  bool _initialized = false;
  bool _wantRunning = false;
  bool _listening = false;

  bool get available => _available;

  Future<bool> _ensureInit() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _stt.initialize(
        onError: (_) {
          _listening = false;
          _scheduleRestart();
        },
        onStatus: (s) {
          // Apple ends a recognition session after a pause; loop it.
          if (s == 'done' || s == 'notListening') {
            _listening = false;
            _scheduleRestart();
          }
        },
        debugLogging: false,
      );
    } catch (e) {
      debugPrint('[wake] init failed: $e');
      _available = false;
    }
    return _available;
  }

  /// Begin (or resume) listening for the wake word.
  Future<void> start() async {
    _wantRunning = true;
    if (!await _ensureInit()) return;
    await _listen();
  }

  Future<void> _listen() async {
    if (!_wantRunning || _listening) return;
    try {
      _listening = true;
      await _stt.listen(
        onResult: (r) {
          final words = r.recognizedWords.toLowerCase();
          if (words.contains(phrase)) {
            // Heard it — stop ourselves and hand the mic to the turn.
            _wantRunning = false;
            _listening = false;
            unawaited(_stt.stop());
            onWake();
          }
        },
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 60),
        localeId: 'en_US',
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          onDevice: true,
        ),
      );
    } catch (e) {
      debugPrint('[wake] listen failed: $e');
      _listening = false;
      _scheduleRestart();
    }
  }

  void _scheduleRestart() {
    if (!_wantRunning || _listening) return;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_wantRunning && !_listening) _listen();
    });
  }

  /// Stop listening and release the mic (before a recording turn).
  Future<void> stop() async {
    _wantRunning = false;
    _listening = false;
    try {
      await _stt.stop();
    } catch (_) {}
    try {
      await _stt.cancel();
    } catch (_) {}
  }
}
