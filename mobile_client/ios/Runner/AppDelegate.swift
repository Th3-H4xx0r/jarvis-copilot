import Flutter
import UIKit
import UserNotifications
#if canImport(AppIntents)
import AppIntents
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var pendingDeepLink: URL?
    private var pairChannel: FlutterMethodChannel?
    // "Talk to JarvisCopilot" Siri App Intent → open Voice + start a turn.
    private var intentsChannel: FlutterMethodChannel?
    // Shortcuts x-callback-url result routing. Running a Shortcut opens
    // `shortcuts://x-callback-url/run-shortcut?...&x-success=jarviscopilot://shortcut-result?rid=…`
    // and iOS re-opens our app with the shortcut's output. We forward
    // that back to Dart, which matches it to the awaiting run_shortcut
    // call by `rid`.
    private var shortcutsChannel: FlutterMethodChannel?
    private var pendingShortcutCallbacks: [URL] = []

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // UIScene migration: pre-create the FlutterViewController + window
        // here, before plugin registration. Two things depend on this:
        //
        //   1. FlutterSceneDelegate.scene(_:willConnectTo:) detects an
        //      AppDelegate-owned rootViewController and moves it into the
        //      scene's window (engine's moveRootViewControllerFrom:to:).
        //      The scene's visible root therefore IS this controller —
        //      not a placeholder — so Flutter actually renders.
        //   2. FlutterAppDelegate.registrarForPlugin: routes to
        //      rootViewController.pluginRegistry when that controller is
        //      a FlutterViewController, otherwise to the launchEngine.
        //      Registering plugins now connects them to this controller's
        //      engine — which is the one the scene then displays — so
        //      platform-channel calls from Dart reach the right engine.
        //
        // This also satisfies plugins that capture
        // UIApplication.shared.delegate!.window!!.rootViewController!
        // synchronously inside register (e.g. flutter_contacts) — they
        // capture the real visible controller, not a placeholder.
        let window = UIWindow()
        window.rootViewController = FlutterViewController()
        self.window = window

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
        // Shortcuts channel: Dart→native `list` (iOS can't enumerate user
        // shortcuts, so []), and native→Dart `shortcutResult`/`shortcutError`
        // delivered when a Shortcut's x-callback URL re-opens the app.
        let sc = FlutterMethodChannel(
            name: "jarviscopilot/shortcuts",
            binaryMessenger: controller.binaryMessenger
        )
        shortcutsChannel = sc
        sc.setMethodCallHandler { call, result in
            switch call.method {
            case "list":
                result([])
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        // Replay any shortcut callbacks that arrived before the channel
        // existed (cold launch back into the app).
        let queued = pendingShortcutCallbacks
        pendingShortcutCallbacks.removeAll()
        for url in queued { forwardShortcutCallback(url) }

        // Siri intent channel + observer. The StartVoiceIntent sets a
        // UserDefaults flag (cold launch) and posts a notification (warm).
        intentsChannel = FlutterMethodChannel(
            name: "jarviscopilot/intents",
            binaryMessenger: controller.binaryMessenger
        )
        NotificationCenter.default.removeObserver(
            self, name: Notification.Name("jcStartVoice"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fireStartVoiceIfPending),
            name: Notification.Name("jcStartVoice"), object: nil)
        fireStartVoiceIfPending()

        if let pending = pendingDeepLink {
            pendingDeepLink = nil
            DispatchQueue.main.async { [weak self] in
                self?.handleIncomingURL(pending)
            }
        }
    }

    // ── Deep-link handling ───────────────────────────────────────
    //
    //   jarviscopilot://pair?server=…&code=…            → pairing
    //   jarviscopilot://shortcut-result?rid=…&result=…  → Shortcut output
    //   jarviscopilot://shortcut-error?rid=…&errorMessage=…
    //
    // Called from SceneDelegate.scene(_:openURLContexts:) for live
    // delivery and from scene(_:willConnectTo:) for cold-launch URLs.
    // (Name kept for the SceneDelegate call site.)
    func handlePairDeepLink(_ url: URL) {
        handleIncomingURL(url)
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "jarviscopilot" else { return }
        switch url.host {
        case "shortcut-result", "shortcut-error":
            forwardShortcutCallback(url)
        default:
            forwardPairDeepLink(url)
        }
    }

    // Pre-scene fallback retained for non-scene runtimes.
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        if url.scheme == "jarviscopilot" {
            handleIncomingURL(url)
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

    private func forwardShortcutCallback(_ url: URL) {
        guard let ch = shortcutsChannel else {
            pendingShortcutCallbacks.append(url)
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func val(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value ?? ""
        }
        // rid is the last path component: jarviscopilot://shortcut-result/<rid>
        let rid = url.lastPathComponent
        if url.host == "shortcut-error" {
            ch.invokeMethod("shortcutError", arguments: [
                "rid": rid,
                "error": val("errorMessage"),
            ])
        } else {
            ch.invokeMethod("shortcutResult", arguments: [
                "rid": rid,
                "result": val("result"),
            ])
        }
    }

    // ── Siri "Talk to JarvisCopilot" intent hand-off ────────────
    //
    // StartVoiceIntent sets `jc_pending_voice` (covers cold launch) and
    // posts `jcStartVoice` (covers warm launch). Either way we tell Dart
    // to open the Voice tab and start a turn, then clear the flag.
    @objc func fireStartVoiceIfPending() {
        guard UserDefaults.standard.bool(forKey: "jc_pending_voice") else { return }
        guard let ch = intentsChannel else { return } // retried on next activate
        UserDefaults.standard.set(false, forKey: "jc_pending_voice")
        ch.invokeMethod("startVoice", arguments: nil)
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        super.applicationDidBecomeActive(application)
        fireStartVoiceIfPending()
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

// ── Siri App Intent ──────────────────────────────────────────────
//
// Exposes "Talk to JarvisCopilot" to Siri + Shortcuts (iOS 16+). Siri
// requires the app name in the phrase, so the trigger is e.g. "Hey Siri,
// Talk to JarvisCopilot" (a true custom "Hey Jarvis" wake word isn't
// available to third-party apps). When run, it opens the app; the app
// then jumps to Voice and starts a realtime turn.
#if canImport(AppIntents)
@available(iOS 16.0, *)
struct StartVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to JarvisCopilot"
    static var description = IntentDescription("Open JarvisCopilot and start a voice conversation.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "jc_pending_voice")
        NotificationCenter.default.post(name: Notification.Name("jcStartVoice"), object: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct JarvisAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Avoid "Talk to …" / "Call …" / "Hey …" — Siri routes those to
        // telephony/FaceTime and would dial a contact instead of running
        // this intent. These phrases launch the app cleanly.
        AppShortcut(
            intent: StartVoiceIntent(),
            phrases: [
                "Start \(.applicationName) voice",
                "Ask \(.applicationName)",
                "Open \(.applicationName) voice",
                "\(.applicationName) voice",
            ],
            shortTitle: "Start JarvisCopilot voice",
            systemImageName: "mic.fill"
        )
    }
}
#endif
