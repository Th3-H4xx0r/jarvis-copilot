/// App-wide foreground/background state, updated by the lifecycle observer in
/// main.dart. The invoke runner reads this to decide whether a foreground-
/// required skill (one that calls openURL / launches an app) can run NOW or
/// must be deferred to a notification tap.
///
/// Why this exists: iOS keeps the app + its WebSocket alive in the background
/// (the app holds `audio`/`location` background modes), so server invokes keep
/// arriving over the live WS while backgrounded — but openURL is blocked there.
/// We can't infer "backgrounded" from "WS down"; we must track the real
/// lifecycle. See `shouldDeferToForeground`.
class AppLifecycle {
  AppLifecycle._();

  static bool _isForeground = true;

  /// True while the app is in the foreground (resumed). Defaults to true (cold
  /// launch runs in the foreground); the observer keeps it current.
  ///
  /// Kept as a plain-looking static field (get/set, same call syntax
  /// `AppLifecycle.isForeground = x`) so main.dart's existing
  /// `didChangeAppLifecycleState` assignment needs no changes, while the
  /// setter also fans out to [addListener]s — see BackgroundKeepalive
  /// (Workstream H), which listens here to arm/disarm on background/foreground.
  static bool get isForeground => _isForeground;
  static set isForeground(bool v) {
    if (_isForeground == v) return;
    _isForeground = v;
    _notify();
  }

  static bool _voiceActive = false;

  /// True while the voice controller (lib/voice/voice_controller.dart) has an
  /// active recording session. The voice controller does NOT import this
  /// service today; it should set this at the start/end of a session:
  ///
  ///   AppLifecycle.voiceActive = true;  // when the mic session starts
  ///   AppLifecycle.voiceActive = false; // when it stops/disposes
  ///
  /// BackgroundKeepalive listens for this to avoid fighting the voice
  /// controller's own AVAudioSession configuration.
  static bool get voiceActive => _voiceActive;
  static set voiceActive(bool v) {
    if (_voiceActive == v) return;
    _voiceActive = v;
    _notify();
  }

  static final List<void Function()> _listeners = [];

  /// Registered by BackgroundKeepalive to re-sync whenever foreground state
  /// or voice-active state changes.
  static void addListener(void Function() cb) => _listeners.add(cb);
  static void removeListener(void Function() cb) => _listeners.remove(cb);

  static void _notify() {
    for (final cb in List<void Function()>.from(_listeners)) {
      cb();
    }
  }
}

/// A foreground-required skill must be deferred (notify + run on tap) when the
/// app is not currently in the foreground. Pure so it's unit-testable.
bool shouldDeferToForeground({
  required bool requiresForeground,
  required bool isForeground,
}) =>
    requiresForeground && !isForeground;
