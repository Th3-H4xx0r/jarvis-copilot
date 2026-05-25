import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import 'wake_word.dart';

/// App-wide foreground "Hey Jarvis" wake word.
///
/// iOS can't run a custom wake word in the background or over other apps,
/// so this only listens while JarvisCopilot is foregrounded and no voice
/// turn is active (the mic can't be shared with the recorder). On a hit it
/// asks the app to open Voice + start a realtime turn via [onWake]. It's
/// opt-in (off by default) and battery-heavy while on.
class WakeService with WidgetsBindingObserver {
  WakeService({required this.onWake});

  /// Called when the wake word is heard — typically `requestVoiceLaunch`.
  final VoidCallback onWake;

  final ValueNotifier<bool> enabled = ValueNotifier(false);
  WakeWordListener? _listener;
  bool _foreground = true;
  bool _suppressed = false; // a voice turn currently owns the mic

  void init() => WidgetsBinding.instance.addObserver(this);

  /// Toggle the wake word. Returns false if mic permission was denied
  /// (the caller should show the Settings dialog).
  Future<bool> setEnabled(bool on) async {
    if (!on) {
      enabled.value = false;
      await _listener?.stop();
      return true;
    }
    final granted = (await Permission.microphone.request()).isGranted;
    if (!granted) return false;
    enabled.value = true;
    _listener ??= WakeWordListener(onWake: _onHit);
    _maybeListen();
    return true;
  }

  void _onHit() {
    // The listener stopped itself; mark suppressed so we don't restart
    // before the turn grabs the mic, then ask the app to open Voice.
    _suppressed = true;
    onWake();
  }

  /// A voice turn started — release the wake mic.
  void suppress() {
    _suppressed = true;
    _listener?.stop();
  }

  /// A voice turn ended — resume listening if still enabled + foreground.
  void resume() {
    _suppressed = false;
    _maybeListen();
  }

  void _maybeListen() {
    if (enabled.value && _foreground && !_suppressed) {
      _listener?.start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _maybeListen();
    } else {
      _listener?.stop(); // iOS suspends the mic in the background anyway
    }
  }
}
