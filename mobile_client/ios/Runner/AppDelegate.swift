import Flutter
import UIKit
import UserNotifications

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    private var pendingDeepLink: URL?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // ── Push registration ─────────────────────────────────────
        // We register here so the OS hands us the APNs device token in
        // didRegisterForRemoteNotificationsWithDeviceToken. The actual
        // FCM token is observed on the Dart side via firebase_messaging.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }

        // Defer the cold-launch deep link until after the FlutterEngine
        // is alive. didFinishLaunchingWithOptions returns BEFORE Flutter
        // is ready, so we squirrel it away and replay it once the engine
        // and its rootViewController are attached.
        if let url = launchOptions?[.url] as? URL {
            pendingDeepLink = url
        }

        let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

        // ── Platform channels (AFTER super so FlutterViewController exists) ──
        if let controller = window?.rootViewController as? FlutterViewController {
            ShortcutsBridge.register(with: controller)
            HealthKitBridge.register(with: controller)
            TorchBridge.register(with: controller)
            AppOpenBridge.register(with: controller)
            SmsComposeBridge.register(with: controller)
        }

        // Replay any pending deep link now that the channel exists.
        if let pending = pendingDeepLink {
            pendingDeepLink = nil
            DispatchQueue.main.async { [weak self] in
                self?.forwardPairDeepLink(pending)
            }
        }

        return ok
    }

    // ── Deep-link handling ───────────────────────────────────────
    //
    // jarviscopilot://pair?server=https%3A%2F%2F1.2.3.4%3A8787&code=ABC-DEF
    //
    // We forward to a MethodChannel ("jarviscopilot/pair") so the
    // Dart side can navigate to PairPage with prefilled fields.
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        if url.scheme == "jarviscopilot" {
            forwardPairDeepLink(url)
            return true
        }
        return super.application(app, open: url, options: options)
    }

    private func forwardPairDeepLink(_ url: URL) {
        guard let controller = window?.rootViewController as? FlutterViewController else {
            pendingDeepLink = url
            return
        }
        let ch = FlutterMethodChannel(name: "jarviscopilot/pair", binaryMessenger: controller.binaryMessenger)
        ch.invokeMethod("openPair", arguments: ["url": url.absoluteString])
    }

    // ── Silent push wakeup ───────────────────────────────────────
    //
    // FCM forwards `content-available:1` pushes here. We get ~30s of
    // background time. Dart's firebase_messaging onMessage runs in
    // parallel; the completion handler must be called on the main
    // queue once we believe work is settled.
    override func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Hand off to the Flutter app; firebase_messaging will deliver
        // it through its background isolate. We complete with
        // .newData unconditionally — APNs only cares that we finished
        // before the OS suspends us.
        super.application(application,
                          didReceiveRemoteNotification: userInfo,
                          fetchCompletionHandler: completionHandler)
    }
}
