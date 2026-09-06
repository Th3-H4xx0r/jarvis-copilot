import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The body `POST /api/devices/mobile/token` carries.
///
/// Pure so the shape can be asserted without a network: the server keys a device
/// row off `push_token` + `bundle_id`, and gets everything else it needs to pick
/// an APNs host and label the device in the Devices tab from here.
///
/// Port of `PushHandler._registerToken` in `services/push_handler.dart`, plus the
/// `bundle_id` / `push_env` fields this app's own `BridgeClient.registerPush`
/// added (the Flutter client only ever ran against one bundle id).
struct PushTokenRegistration: Equatable, Sendable {
    var token: String
    var deviceName: String
    var bundleID: String
    var pushEnvironment: String
    var appVersion: String

    var json: [String: Any] {
        var body: [String: Any] = [
            "platform": "ios",
            "push_kind": "apns",
            "push_token": token,
            "bundle_id": bundleID,
            "push_env": pushEnvironment,
            "app_version": appVersion,
        ]
        // The Flutter client never sent a name and every phone showed up as
        // "mobile" in the Devices tab; the server takes it when offered.
        if !deviceName.isEmpty { body["device_name"] = deviceName }
        return body
    }
}

/// Everything `AppServices` needs from the push layer, so the startup sequence
/// can be asserted against a fake.
@MainActor
protocol PushStarting: AnyObject {
    /// Install the notification delegate + categories, ask for permission, and
    /// register for remote notifications when this device is paired.
    func start()
    /// Drain whatever the bridge queued for us (app resume, notification tap).
    func drainNow() async
}

/// APNs registration, notification categories and the tap → action routing that
/// `PushService` (the pre-port silent-push plumbing) never had.
///
/// `PushService` still owns the `UIApplicationDelegate` half — token capture and
/// the silent-push wake that calls `BridgeClient.drainQueue`. This class owns the
/// parts the Flutter client had and that one lacks:
///
///  * the *visible* notification permission prompt (silent pushes need none, but
///    the deferred-action banners and the coding permission prompts do);
///  * the Approve / Deny / Reply categories;
///  * `device_name` on the token registration, and storing the `device_id` the
///    server hands back (the Flutter `credentials.dart` `device_id`, which the
///    Live Activity token registration needs);
///  * routing a notification tap into `NotificationActionHandler`.
///
/// The poll/result loop is NOT duplicated here: `BridgeClient.drainQueue` already
/// is that loop (`POST /api/devices/mobile/poll` → `DeviceRegistry.invoke` →
/// `POST /api/devices/mobile/result`), dispatching through `InvokeRunner` by way
/// of `PhoneDevice`, so it enforces the same ACL and foreground-defer rules.
@MainActor
final class PushHandler: NSObject, PushStarting {
    static let shared = PushHandler()

    /// Where the server-issued device id is kept. `credentials.dart` stored it in
    /// the Keychain; it is not a secret (the cookie is), so a preference is
    /// enough and keeps it out of the pairing blob.
    static let deviceIDKey = "jc.device_id"

    private let api: JarvisAPI
    private let preferences: KeyValueStore
    private let actions: NotificationActionHandler
    private let runner: InvokeRunner
    private let bridge: BridgeClient

    private var started = false
    private(set) var lastRegistration: PushTokenRegistration?
    /// The token this launch has already registered successfully.
    ///
    /// `PushService.submit` posts the token TWICE — once through
    /// `BridgeClient.registerPush` and once here — and iOS re-delivers the same
    /// token on every launch (and sometimes more than once per launch). The rows
    /// are an upsert so a duplicate is harmless, but it is a wasted round trip on
    /// a cold start, so the second one is dropped. Only a SUCCESSFUL post counts:
    /// a failed one has to stay retryable.
    private(set) var lastSentToken: String?
    /// What iOS answered when we asked for visible notifications. nil until we
    /// have asked. Mirrored into preferences so Settings can render the
    /// "Notifications are off" row without asking again.
    private(set) var notificationsGranted: Bool?
    /// The failure of the last token registration attempt, or nil when the last
    /// one succeeded. Without it a phone that never registers its token looks
    /// identical to one that did — every push silently goes nowhere.
    private(set) var lastRegistrationError: String?
    private(set) var registrationAttempts = 0

    /// Back-off between token-registration attempts. A failure here costs the
    /// device every push until the next cold launch, so it is worth retrying —
    /// but only a few times: the bridge socket carries the same traffic while
    /// the app is alive.
    static let registrationRetryDelays: [TimeInterval] = [2, 10, 30]

    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    init(api: JarvisAPI = .shared,
         preferences: KeyValueStore = UserDefaults.standard,
         actions: NotificationActionHandler? = nil,
         runner: InvokeRunner = .shared,
         bridge: BridgeClient = .shared,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.api = api
        self.preferences = preferences
        self.actions = actions ?? NotificationActionHandler()
        self.runner = runner
        self.bridge = bridge
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.notificationsGranted = preferences.bool(SettingsStore.Keys.notificationsGranted)
        super.init()
    }

    /// Record what iOS said about visible notifications.
    ///
    /// A refusal is not an error path anywhere — nothing throws, the banners
    /// simply never appear — so unless it is written down the user has no way
    /// to find out that approvals and deferred actions are going nowhere.
    func recordNotificationAuthorization(_ granted: Bool) {
        notificationsGranted = granted
        preferences.set(granted, forKey: SettingsStore.Keys.notificationsGranted)
        if !granted {
            JcLog.services.error("notification authorization refused — banners will not appear")
        }
    }

    /// The id the server assigned this phone, once a token registration has come
    /// back. Nil before the first successful registration.
    var deviceID: String? {
        let id = preferences.string(Self.deviceIDKey) ?? ""
        return id.isEmpty ? nil : id
    }

    func start() {
        guard !started else { return }
        started = true
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        // Set the delegate before anything else: a tap that LAUNCHED the app is
        // delivered as soon as one exists, and there is no way to ask for it later.
        center.delegate = self
        center.setNotificationCategories(NotificationCategories.all())
        Task { [weak self] in
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .badge, .sound])) ?? false
            self?.recordNotificationAuthorization(granted)
            self?.registerForRemoteNotifications()
        }
        #else
        registerForRemoteNotifications()
        #endif
    }

    private func registerForRemoteNotifications() {
        #if canImport(UIKit)
        // Silent pushes need no permission, so this is deliberately not gated on
        // the authorization result — only on being paired, because an unpaired
        // app has nowhere to send the token.
        guard bridge.isPaired else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func drainNow() async {
        await bridge.drainQueue(foreground: true)
    }

    // MARK: - Token registration

    /// Registers the APNs token, sending the device's name and storing the
    /// `device_id` the server replies with.
    ///
    /// Retried with back-off: a transient failure here used to be invisible
    /// until the next cold launch, and a device without a registered token gets
    /// no pushes at all — no coding approvals, no deferred-action banners.
    func registerToken(_ token: String) async {
        guard !token.isEmpty else { return }
        guard token != lastSentToken else { return }
        let registration = PushTokenRegistration(
            token: token,
            deviceName: preferences.string(SettingsStore.Keys.deviceName)
                ?? SettingsStore.defaultDeviceName,
            bundleID: Bundle.main.bundleIdentifier ?? "com.jarviscopilot.jarviscopilotMobileAndIOS",
            pushEnvironment: BridgeClient.apsEnvironment,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        lastRegistration = registration

        for attempt in 0...Self.registrationRetryDelays.count {
            if attempt > 0 {
                // A cancelled sleep means the app is going away; stop retrying
                // rather than firing the request into a dying process.
                do { try await sleeper(Self.registrationRetryDelays[attempt - 1]) }
                catch { return }
            }
            registrationAttempts += 1
            do {
                let body = try await api.post("/api/devices/mobile/token",
                                              json: registration.json).object()
                lastSentToken = token
                lastRegistrationError = nil
                if let id = body["device_id"] as? String, !id.isEmpty {
                    preferences.set(id, forKey: Self.deviceIDKey)
                }
                return
            } catch {
                lastRegistrationError = JcLog.report(JcLog.services, "push token registration", error)
            }
        }
    }

    // MARK: - Taps

    /// Route a decoded tap: post the permission verdict and/or run whatever
    /// deferred action the banner carried.
    func handle(_ action: NotificationAction) async {
        let recovered = await actions.handle(action)
        // A recovered action is only queued; the drain is what runs it, and it
        // can only run now because the tap brought us to the foreground.
        if recovered != nil { await runner.drainPending() }
    }
}

#if canImport(UserNotifications)
extension PushHandler: UNUserNotificationCenterDelegate {

    /// Show server notifications while the app is open too — a permission prompt
    /// the user never sees is a session that silently stalls.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let action = NotificationAction.decode(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            userText: text)
        await handle(action)
    }
}
#endif
