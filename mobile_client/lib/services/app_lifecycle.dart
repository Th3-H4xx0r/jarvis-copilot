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

  /// True while the app is in the foreground (resumed). Defaults to true (cold
  /// launch runs in the foreground); the observer keeps it current.
  static bool isForeground = true;
}

/// A foreground-required skill must be deferred (notify + run on tap) when the
/// app is not currently in the foreground. Pure so it's unit-testable.
bool shouldDeferToForeground({
  required bool requiresForeground,
  required bool isForeground,
}) =>
    requiresForeground && !isForeground;
