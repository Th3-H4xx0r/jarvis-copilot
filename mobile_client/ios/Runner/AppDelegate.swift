import Flutter
import UIKit
import UserNotifications
import CoreLocation
import CryptoKit
#if canImport(AppIntents)
import AppIntents
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {

    private var pendingDeepLink: URL?
    private var pairChannel: FlutterMethodChannel?
    // "Talk to JarvisCopilot" Siri App Intent → open Voice + start a turn.
    private var intentsChannel: FlutterMethodChannel?
    // Background location: Significant-Location-Change monitoring. This is
    // the only mechanism that survives a force-quit — iOS relaunches the
    // app on ~500 m movement, even after the user swiped it away. On each
    // update we push the fix to the server natively (no Flutter needed).
    private var intentsLocationChannel: FlutterMethodChannel?
    private var locationManager: CLLocationManager?
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

        // Activate the Apple Watch bridge here (not in attachFlutterController)
        // so it's live even when iOS is background-launched by
        // WCSession.sendMessage — the native relay needs no Flutter engine.
        WatchBridge.shared.activate()

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

        // Re-arm significant-location-change monitoring on every launch
        // (including when iOS relaunched us in the background for a
        // location event after a force-quit). Self-contained — does not
        // need the Flutter engine.
        startSlcIfEnabled()

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

        // Location channel: Dart tells us to start/stop SLC and hands over
        // the server URL + cookie + cert pin so we can push fixes natively
        // (incl. after a force-quit relaunch, when Dart isn't running).
        let locCh = FlutterMethodChannel(
            name: "jarviscopilot/location",
            binaryMessenger: controller.binaryMessenger
        )
        intentsLocationChannel = locCh
        locCh.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            if call.method == "setTracking", let a = call.arguments as? [String: Any] {
                let enabled = (a["enabled"] as? Bool) ?? false
                let d = UserDefaults.standard
                d.set(enabled, forKey: "jc_track_location")
                if enabled {
                    d.set((a["serverUrl"] as? String) ?? "", forKey: "jc_server_url")
                    d.set((a["cookie"] as? String) ?? "", forKey: "jc_cookie")
                    d.set((a["certSha256"] as? String) ?? "", forKey: "jc_cert_sha256")
                    self.startSlc()
                } else {
                    self.stopSlc()
                }
                result(true)
            } else if call.method == "getDiag" {
                let d = UserDefaults.standard
                result([
                    "tracking": d.bool(forKey: "jc_track_location"),
                    "lastSlc": d.double(forKey: "jc_last_slc_ts"),
                    "lastPush": d.double(forKey: "jc_last_push_ts"),
                    "lastPushStatus": d.string(forKey: "jc_last_push_status") ?? "",
                ])
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        // Apple Watch: Dart pushes the paired creds → UserDefaults (read by the
        // native WatchBridge relay) and the login-state → the watch via WCSession
        // application context. Mirrors the location channel above.
        let watchCh = FlutterMethodChannel(
            name: "jarviscopilot/watch",
            binaryMessenger: controller.binaryMessenger
        )
        watchCh.setMethodCallHandler { call, result in
            if call.method == "syncCredentials", let a = call.arguments as? [String: Any] {
                let d = UserDefaults.standard
                d.set((a["serverUrl"] as? String) ?? "", forKey: "jc_server_url")
                d.set((a["cookie"] as? String) ?? "", forKey: "jc_cookie")
                d.set((a["certSha256"] as? String) ?? "", forKey: "jc_cert_sha256")
                // CF Access service token → read by WatchBridge.authHeaders so the
                // watch relay clears Cloudflare Access on a tunnel-fronted server.
                d.set((a["cfClientId"] as? String) ?? "", forKey: "jc_cf_client_id")
                d.set((a["cfClientSecret"] as? String) ?? "", forKey: "jc_cf_client_secret")
                WatchBridge.shared.pushLoginState((a["loggedIn"] as? Bool) ?? false)
                result(true)
            } else if call.method == "getWatchStatus" {
                result(WatchBridge.shared.status())
            } else if call.method == "sendHaptic" {
                let a = call.arguments as? [String: Any]
                WatchBridge.shared.sendHaptic(count: (a?["count"] as? Int) ?? 3)
                result(true)
            } else if call.method == "sendClip",
                      let a = call.arguments as? [String: Any],
                      let b64 = a["audioBase64"] as? String,
                      let data = Data(base64Encoded: b64) {
                WatchBridge.shared.sendClip(data)
                result(true)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

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
        case "voice":
            // Lock Screen / Home Screen widget tap → open Voice + start a turn,
            // reusing the same path as the Siri StartVoiceIntent.
            UserDefaults.standard.set(true, forKey: "jc_pending_voice")
            fireStartVoiceIfPending()
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

    // ── Background location (significant-change, survives force-quit) ──
    private func startSlcIfEnabled() {
        if UserDefaults.standard.bool(forKey: "jc_track_location") { startSlc() }
    }

    private func startSlc() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        if locationManager == nil {
            let m = CLLocationManager()
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyHundredMeters
            m.pausesLocationUpdatesAutomatically = false
            // Requires the `location` UIBackgroundMode (declared) + Always
            // authorization (requested on the Dart side) to deliver in the
            // background.
            m.allowsBackgroundLocationUpdates = true
            locationManager = m
        }
        locationManager?.startMonitoringSignificantLocationChanges()
    }

    private func stopSlc() {
        locationManager?.stopMonitoringSignificantLocationChanges()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Diagnostic: record that an SLC event arrived (visible in Settings).
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "jc_last_slc_ts")
        NSLog("[jc-loc] SLC update %f,%f state=%ld",
              loc.coordinate.latitude, loc.coordinate.longitude,
              UIApplication.shared.applicationState.rawValue)
        // Foreground fixes are reported by the Dart geolocator stream; only
        // push from here when we're backgrounded (incl. a force-quit
        // relaunch) to avoid duplicate rows.
        if UIApplication.shared.applicationState != .active {
            _pushLocationNatively(
                lat: loc.coordinate.latitude,
                lng: loc.coordinate.longitude,
                accuracy: loc.horizontalAccuracy
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        UserDefaults.standard.set("loc err: \(error.localizedDescription)", forKey: "jc_last_push_status")
        NSLog("[jc-loc] location error: %@", error.localizedDescription)
    }

    private func _pushLocationNatively(lat: Double, lng: Double, accuracy: Double) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "jc_track_location") else { return }
        var base = (d.string(forKey: "jc_server_url") ?? "").trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/devices/mobile/location") else { return }
        let cookie = d.string(forKey: "jc_cookie") ?? ""
        let pin = d.string(forKey: "jc_cert_sha256") ?? ""

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let payload: [String: Any] = [
            "lat": lat, "lng": lng, "accuracy": accuracy,
            "ts": Date().timeIntervalSince1970,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // Keep ~25s of background time so the request can finish.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "jcLocPush") {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        let poster = PinnedPoster(pinHex: pin)
        let session = URLSession(configuration: .ephemeral, delegate: poster, delegateQueue: nil)
        let task = session.dataTask(with: req) { _, resp, err in
            let d = UserDefaults.standard
            d.set(Date().timeIntervalSince1970, forKey: "jc_last_push_ts")
            if let http = resp as? HTTPURLResponse {
                d.set("HTTP \(http.statusCode)", forKey: "jc_last_push_status")
            } else if let err = err {
                d.set("err: \(err.localizedDescription)", forKey: "jc_last_push_status")
            } else {
                d.set("sent", forKey: "jc_last_push_status")
            }
            NSLog("[jc-loc] push result: %@", d.string(forKey: "jc_last_push_status") ?? "?")
            session.finishTasksAndInvalidate()
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        task.resume()
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

// ── Cert-pinned one-shot POST (for native background location push) ──
//
// Mirrors the Dart pinning: validate the leaf cert's SHA-256 (of its DER)
// against the fingerprint captured at pair time before trusting the TLS
// connection. Used so a force-quit relaunch can report location without
// the Flutter engine / Dio.
final class PinnedPoster: NSObject, URLSessionDelegate {
    private let pinHex: String
    init(pinHex: String) { self.pinHex = pinHex.lowercased() }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var leaf: SecCertificate?
        if #available(iOS 15.0, *) {
            leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard !pinHex.isEmpty, let cert = leaf else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(cert) as Data
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if hex == pinHex {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
