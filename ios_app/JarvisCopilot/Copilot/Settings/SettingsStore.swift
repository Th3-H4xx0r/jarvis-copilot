import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Everything the settings screen needs from `BridgeClient`. Behind a protocol so
/// the store can be exercised without a Keychain, a socket or an audio session.
@MainActor
protocol SettingsBridging: AnyObject {
    var serverURL: String { get }
    var isPaired: Bool { get }
    /// The "stay connected in the background" switch: whether `BridgeClient`
    /// holds the silent-audio keepalive. The bridge socket is not affected.
    var keepaliveEnabled: Bool { get set }
    func unpair()
}

extension BridgeClient: SettingsBridging {
    var keepaliveEnabled: Bool {
        get { backgroundKeepalive }
        set { backgroundKeepalive = newValue }
    }
}

/// Background location tracking. Production is `BackgroundLocationService.shared`
/// (`Copilot/Services/BackgroundLocation.swift`); tests inject a double.
@MainActor
protocol LocationTracking: AnyObject {
    /// Returns whether tracking is actually on afterwards — `false` when the user
    /// refused Always-location, in which case the switch must stay off rather
    /// than lying about what the app can do.
    func setEnabled(_ on: Bool) async -> Bool
}

/// The Live Activity master switch, as the settings screen uses it.
///
/// Behind a protocol so the toggle can be asserted without ActivityKit: turning
/// the setting off has to END the running activity, not just record a
/// preference, or a stale island survives on the Lock Screen.
@MainActor
protocol LiveActivityToggling: AnyObject {
    func setEnabled(_ on: Bool)
}

extension LiveActivityCoordinator: LiveActivityToggling {}

/// The settings screen's state.
///
/// Preferences go through `KeyValueStore` (so tests use `MemoryKeyValueStore`);
/// credentials stay in `BridgeClient`'s Keychain, reached through
/// `SettingsBridging`. Mutations are explicit `set…` methods rather than settable
/// properties because several of them have side effects (a permission prompt, a
/// socket reconnect) that a `Binding` write shouldn't hide.
@MainActor
@Observable
final class SettingsStore {

    /// Preference keys. Namespaced so they can't collide with the app's older
    /// `UserDefaults` entries.
    enum Keys {
        static let deviceName = "jc.device_name"
        static let trackLocation = "jc.track_location"
        static let liveActivities = "jc.live_activities"
        /// What iOS last said about the *visible* notification permission.
        /// Written by whoever learned it — `PushHandler` when it asks at launch,
        /// `LocalConnectionNotifier` when a post is refused — so this screen can
        /// report it without a second `UNUserNotificationCenter` round trip
        /// (which would need an entitlement-bearing host to answer honestly).
        static let notificationsGranted = "jc.notifications_granted"
    }

    /// What the device calls itself when nothing was typed.
    static var defaultDeviceName: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
        #else
        return "Mac"
        #endif
    }

    private(set) var deviceName: String
    private(set) var trackLocation: Bool
    private(set) var liveActivities: Bool
    private(set) var keepalive: Bool
    /// nil until something has actually asked iOS; false once a request or a
    /// post came back refused. Drives the "Notifications are off" row — without
    /// it a denied permission is invisible and every deferred action, coding
    /// approval and connection banner silently goes nowhere.
    private(set) var notificationsGranted: Bool?
    /// Set when a toggle could not be honoured (permission refused, …).
    var errorMessage: String?

    /// True only when we KNOW they are off (nil means nobody has asked yet).
    var notificationsAreOff: Bool { notificationsGranted == false }

    var serverURL: String { bridge.serverURL }
    var isPaired: Bool { bridge.isPaired }

    private let preferences: KeyValueStore
    private let bridge: SettingsBridging
    // Internal rather than private so the wiring test can assert that a
    // default-constructed store really reaches the production singletons — the
    // whole failure mode here is a switch that quietly toggles nothing.
    let location: any LocationTracking
    let liveActivity: any LiveActivityToggling
    /// Wipes what the embedded server tabs left in WebKit's own storage.
    /// Injectable because `WKWebsiteDataStore` can't be observed from a test.
    private let clearWebsiteData: () -> Void
    /// Fires when this phone stops talking to the server it was paired with.
    /// Production forgets `ChatAPI`'s process-wide feature probe; injectable so
    /// the call can be asserted without reaching into that global.
    private let onServerChanged: () -> Void

    /// `location` / `liveActivity` are optional rather than defaulted to their
    /// production singletons: a default argument expression is evaluated in the
    /// caller's (nonisolated) context, and both are main-actor-isolated.
    init(preferences: KeyValueStore = UserDefaults.standard,
         bridge: SettingsBridging = BridgeClient.shared,
         location: (any LocationTracking)? = nil,
         liveActivity: (any LiveActivityToggling)? = nil,
         clearWebsiteData: (() -> Void)? = nil,
         onServerChanged: (() -> Void)? = nil) {
        self.preferences = preferences
        self.bridge = bridge
        self.onServerChanged = onServerChanged ?? { ChatAPI.resetFeatureDetection() }
        self.location = location ?? BackgroundLocationService.shared
        self.liveActivity = liveActivity ?? LiveActivityCoordinator.shared
        self.clearWebsiteData = clearWebsiteData ?? { WebViewCookies.clearAll() }
        self.deviceName = preferences.string(Keys.deviceName) ?? Self.defaultDeviceName
        self.trackLocation = preferences.bool(Keys.trackLocation) ?? false
        // On unless explicitly switched off.
        self.liveActivities = preferences.bool(Keys.liveActivities) ?? true
        // The bridge owns the live value; it lives in the Keychain.
        self.keepalive = bridge.keepaliveEnabled
        self.notificationsGranted = preferences.bool(Keys.notificationsGranted)
    }

    /// Re-read the notification flag (the screen calls this on appear — the
    /// permission can change in iOS Settings while the app is backgrounded, and
    /// whoever notices writes the preference).
    func refreshNotificationStatus() {
        notificationsGranted = preferences.bool(Keys.notificationsGranted)
    }

    // MARK: Identity

    func setDeviceName(_ name: String) {
        let trimmed = jcTrim(name)
        deviceName = trimmed.isEmpty ? Self.defaultDeviceName : trimmed
        preferences.set(trimmed.isEmpty ? nil : trimmed, forKey: Keys.deviceName)
    }

    // MARK: Toggles

    /// Background location history for the assistant. Needs Always-location and
    /// costs battery, so it is opt-in and stays off if permission is refused.
    func setTrackLocation(_ on: Bool) async {
        let granted = await location.setEnabled(on)
        guard !on || granted else {
            errorMessage = "Location permission needed. Enable Location → Always "
                         + "for JarvisCopilot in iOS Settings."
            return
        }
        errorMessage = nil
        trackLocation = on
        preferences.set(on ? true : nil, forKey: Keys.trackLocation)
    }

    /// Coding sessions on the Lock Screen / Dynamic Island.
    ///
    /// The coordinator is told directly rather than left to notice the
    /// preference on its next launch: switching this off has to END the running
    /// activity, and a stale island left on the Lock Screen after the user turned
    /// the feature off is the one outcome that is never acceptable.
    func setLiveActivities(_ on: Bool) {
        liveActivities = on
        preferences.set(on, forKey: Keys.liveActivities)
        liveActivity.setEnabled(on)
    }

    /// "Stay connected in the background": the silent-audio keepalive that keeps
    /// the bridge socket and BLE links alive while the app is backgrounded. The
    /// socket itself stays governed by bridge mode.
    func setKeepalive(_ on: Bool) {
        keepalive = on
        bridge.keepaliveEnabled = on
    }

    // MARK: Unpair

    /// Clears the pairing. `BridgeClient.unpair()` drops the socket, wipes the
    /// Keychain and stops the keepalive; the preferences that describe *this*
    /// pairing go with it, so a re-pair starts clean.
    func unpair() {
        bridge.unpair()
        preferences.set(nil, forKey: Keys.deviceName)
        preferences.set(nil, forKey: Keys.trackLocation)
        deviceName = Self.defaultDeviceName
        trackLocation = false
        keepalive = bridge.keepaliveEnabled
        // The embedded server tabs run in a WKWebView, and everything they store
        // (the `hermes_session` cookie above all) lives in WebKit's own store —
        // NOT the Keychain the bridge just wiped. Leaving it behind would hand
        // the next person to pair this phone a logged-in webui.
        clearWebsiteData()
        // …and what we learned about the server we just left. The probe is
        // process-wide, so without this the next pairing inherits the previous
        // server's verdict for the rest of the launch.
        onServerChanged()
    }
}
