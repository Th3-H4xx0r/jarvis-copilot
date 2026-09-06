import Foundation

/// App-wide foreground/background state. The invoke runner reads this to decide
/// whether a foreground-required skill (one that calls `UIApplication.open` or
/// launches an app) can run NOW or must be deferred to a notification tap.
///
/// Why this exists: iOS keeps this app and its bridge socket alive in the
/// background (it holds the `audio`/`bluetooth-central` background modes), so
/// server invokes keep arriving while backgrounded — but `openURL` is blocked
/// there. We can't infer "backgrounded" from "socket down"; we must track the
/// real lifecycle.
///
/// Port of `mobile_client/lib/services/app_lifecycle.dart`.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private var _isForeground = true
    private var _voiceActive = false
    private var listeners: [UUID: () -> Void] = [:]

    init() {}

    /// True while the app is in the foreground (resumed). Defaults to true — a
    /// cold launch runs in the foreground; the scene observer keeps it current.
    var isForeground: Bool {
        get { _isForeground }
        set {
            guard _isForeground != newValue else { return }
            _isForeground = newValue
            notify()
        }
    }

    /// True while a voice session holds the mic. Kept here so the keepalive and
    /// the audio session don't fight each other.
    var voiceActive: Bool {
        get { _voiceActive }
        set {
            guard _voiceActive != newValue else { return }
            _voiceActive = newValue
            notify()
        }
    }

    /// Observe foreground/voice transitions. The returned token removes the
    /// observer — a closure identity can't be compared in Swift the way Dart
    /// compares function references.
    @discardableResult
    func addListener(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        listeners[token] = callback
        return token
    }

    func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    private func notify() {
        for callback in listeners.values { callback() }
    }
}

/// A foreground-required skill must be deferred (notify + run on tap) when the
/// app is not currently in the foreground. Pure so it's unit-testable.
func shouldDeferToForeground(requiresForeground: Bool, isForeground: Bool) -> Bool {
    requiresForeground && !isForeground
}
