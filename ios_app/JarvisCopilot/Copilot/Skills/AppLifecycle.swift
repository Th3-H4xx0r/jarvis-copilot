import Foundation

/// App-wide foreground/background state. The invoke runner reads this to decide
/// whether a foreground-required skill (one that calls `UIApplication.open` or
/// launches an app) can run NOW or must be deferred to a notification tap.
///
/// The background keepalive keeps the bridge socket alive while backgrounded, so
/// invokes keep arriving there, but `openURL` is blocked. "Socket up" says nothing
/// about being on screen; the scene observer keeps this current.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    /// True while the app is in the foreground. A cold launch starts there.
    var isForeground = true

    init() {}
}

/// A foreground-required skill must be deferred (notify + run on tap) when the
/// app is not currently in the foreground.
func shouldDeferToForeground(requiresForeground: Bool, isForeground: Bool) -> Bool {
    requiresForeground && !isForeground
}
