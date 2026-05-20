import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var pendingDeepLink: URL?
    private var pairChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Push registration — APNs token comes back via
        // FlutterAppDelegate's didRegisterForRemoteNotificationsWithDeviceToken;
        // the FCM token is observed on the Dart side via firebase_messaging.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }

        // Pre-scene fallback: capture the cold-launch URL. In scene
        // mode, SceneDelegate.scene(_:willConnectTo:) hands the same URL
        // to handlePairDeepLink via connectionOptions.urlContexts.
        if let url = launchOptions?[.url] as? URL {
            pendingDeepLink = url
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── Channel wiring (called by SceneDelegate once the FlutterViewController
    //    exists) ──────────────────────────────────────────────────
    //
    // FlutterAppDelegate.window is nil under UIScene lifecycle, so we
    // can no longer look up the controller here. SceneDelegate hands
    // it to us once super.scene(willConnectTo:) has built the engine.
    func attachFlutterController(_ controller: FlutterViewController) {
        let ch = FlutterMethodChannel(
            name: "jarviscopilot/pair",
            binaryMessenger: controller.binaryMessenger
        )
        pairChannel = ch
        ch.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            switch call.method {
            case "takePendingPairUrl":
                result(self.pendingDeepLink?.absoluteString)
                self.pendingDeepLink = nil
            case "clearPendingPairUrl":
                self.pendingDeepLink = nil
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        if let pending = pendingDeepLink {
            pendingDeepLink = nil
            DispatchQueue.main.async { [weak self] in
                self?.forwardPairDeepLink(pending)
            }
        }
    }

    // ── Deep-link handling ───────────────────────────────────────
    //
    // jarviscopilot://pair?server=https%3A%2F%2F1.2.3.4%3A8787&code=ABC-DEF
    //
    // Called from SceneDelegate.scene(_:openURLContexts:) for live
    // delivery and from scene(_:willConnectTo:) for cold-launch URLs.
    func handlePairDeepLink(_ url: URL) {
        guard url.scheme == "jarviscopilot" else { return }
        forwardPairDeepLink(url)
    }

    // Pre-scene fallback retained for non-scene runtimes.
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
        guard let ch = pairChannel else {
            // Channel not wired yet — stash and let attachFlutterController
            // replay once the SceneDelegate finishes setup.
            pendingDeepLink = url
            return
        }
        pendingDeepLink = url
        ch.invokeMethod("openPair", arguments: ["url": url.absoluteString])
    }

    // ── Silent push wakeup ───────────────────────────────────────
    //
    // FCM forwards `content-available:1` pushes here. We get ~30s of
    // background time. firebase_messaging delivers the same payload to
    // Dart in parallel; calling super completes the OS handler on the
    // main queue.
    override func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        super.application(application,
                          didReceiveRemoteNotification: userInfo,
                          fetchCompletionHandler: completionHandler)
    }
}
