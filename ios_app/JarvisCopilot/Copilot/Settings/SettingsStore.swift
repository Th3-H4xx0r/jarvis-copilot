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
    /// The "stay connected in the background" switch. In this app that is bridge
    /// mode: `BridgeClient` gates the silent-audio keepalive
    /// (`BackgroundKeepalive.shared.sync(active: enabled && isPaired)`) on it, so
    /// flipping this is what starts and stops the keepalive.
    var keepaliveEnabled: Bool { get set }
    func unpair()
    func connect()
    func disconnect()
}

extension BridgeClient: SettingsBridging {
    /// `enabled` under the boundary's name. Add-only — the setter is
    /// `BridgeClient`'s own, keepalive sync and all.
    var keepaliveEnabled: Bool {
        get { enabled }
        set { enabled = newValue }
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

/// Inert tracker: accepts the preference, tracks nothing. For previews and for
/// any context without CoreLocation — the app itself injects
/// `BackgroundLocationService.shared`.
@MainActor
final class UntrackedLocation: LocationTracking {
    func setEnabled(_ on: Bool) async -> Bool { true }
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

/// Wiping what the embedded server tabs left in WebKit's own storage. Behind a
/// protocol so `unpair()` can be asserted without WebKit (there is no way to
/// observe `WKWebsiteDataStore` from a unit test).
@MainActor
protocol WebsiteDataClearing: AnyObject {
    func clearWebsiteData()
}

/// Production: `WebViewCookies.clearAll()`.
@MainActor
final class DefaultWebsiteDataCleaner: WebsiteDataClearing {
    func clearWebsiteData() { WebViewCookies.clearAll() }
}

/// The settings screen's state, ported from `pages/settings_page.dart`.
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
    /// `UserDefaults` entries; the suffixes match `credentials.dart`.
    enum Keys {
        static let deviceName = "jc.device_name"
        static let trackLocation = "jc.track_location"
        static let liveActivities = "jc.live_activities"
        static let keepalive = "jc.keepalive"
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
    let website: any WebsiteDataClearing
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
         website: (any WebsiteDataClearing)? = nil,
         onServerChanged: (() -> Void)? = nil) {
        self.preferences = preferences
        self.bridge = bridge
        self.onServerChanged = onServerChanged ?? { ChatAPI.resetFeatureDetection() }
        self.location = location ?? BackgroundLocationService.shared
        self.liveActivity = liveActivity ?? LiveActivityCoordinator.shared
        self.website = website ?? DefaultWebsiteDataCleaner()
        self.deviceName = preferences.string(Keys.deviceName) ?? Self.defaultDeviceName
        self.trackLocation = preferences.bool(Keys.trackLocation) ?? false
        // `credentials.dart` reads this as `!= '0'` — on unless explicitly off.
        self.liveActivities = preferences.bool(Keys.liveActivities) ?? true
        // The bridge owns the live value (it lives in the Keychain and the
        // keepalive is already running or not); the mirrored preference is only
        // here so the screen can show the last state before the bridge answers.
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

    /// "Stay connected in the background": the silent-audio keepalive plus the
    /// live bridge socket. Reconnecting here (rather than waiting for the next
    /// foreground) is what makes the switch feel immediate.
    func setKeepalive(_ on: Bool) {
        keepalive = on
        bridge.keepaliveEnabled = on
        preferences.set(on, forKey: Keys.keepalive)
        if on { bridge.connect() } else { bridge.disconnect() }
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
        website.clearWebsiteData()
        // …and what we learned about the server we just left. The probe is
        // process-wide, so without this the next pairing inherits the previous
        // server's verdict for the rest of the launch.
        onServerChanged()
    }
}
