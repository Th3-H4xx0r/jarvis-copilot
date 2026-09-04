import Flutter
import UIKit
import UserNotifications
import CoreLocation
import CryptoKit
import ActivityKit
import WatchConnectivity
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
        // Actionable permission-approval notifications: Approve / Deny / Reply
        // straight from the banner or lock screen (the PreToolUse relay). The
        // server sends these with `category: "PERMISSION_APPROVAL"`.
        let approve = UNNotificationAction(
            identifier: "APPROVE_PERMISSION", title: "Approve", options: [])
        let deny = UNNotificationAction(
            identifier: "DENY_PERMISSION", title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY_PERMISSION", title: "Reply", options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Tell Claude what to do instead…")
        let permCat = UNNotificationCategory(
            identifier: "PERMISSION_APPROVAL", actions: [approve, deny, reply],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([permCat])

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

        // Subscribe to on-device energy/CPU/background-time metrics (delivered
        // ~once/24h) so battery fixes are verifiable in the field. Zero runtime cost.
        MetricKitReporter.shared.register()

        // Workstream H: a background launch triggered by a silent push is
        // exactly the case a live invoke needs the WS bridge up for. Arm the
        // keepalive immediately, natively — Dart's own (better-informed) sync
        // runs moments later once the engine spins up and will correct this
        // if the user has the setting off or isn't paired.
        if launchOptions?[.remoteNotification] != nil {
            Task { @MainActor in BackgroundKeepaliveBridge.armForBackgroundPushLaunch() }
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
        // On-device AI engines (Apple Foundation Models + MLX) + on-device STT.
        OnDeviceAIPlugin.register(messenger: controller.binaryMessenger)
        // Streaming on-device STT during speech (plan 4.1) and the phone's own
        // synthesizer for local acks (plan 4.4).
        SpeechStreamBridge.register(messenger: controller.binaryMessenger)
        LocalTtsBridge.register(messenger: controller.binaryMessenger)
        // Gapless realtime PCM playback (plan 1.7) — see PcmStreamBridge.swift.
        PcmStreamBridge.register(messenger: controller.binaryMessenger)
        // Silent-audio-session keepalive so the bridge WS survives
        // backgrounding (Workstream H); arm/disarm decisions are made in
        // Dart (lib/services/background_keepalive.dart) and delivered here.
        BackgroundKeepaliveBridge.register(messenger: controller.binaryMessenger)

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
        // Dart's authoritative consume of the pending-voice flag (atomic
        // read+clear). Pulling from Dart closes the cold-launch race where the
        // `startVoice` nudge can fire before Dart is ready to hear it — so a
        // tapped widget/Control reliably reaches the Voice screen.
        intentsChannel?.setMethodCallHandler { (call, result) in
            if call.method == "consumePendingVoice" {
                let pending = UserDefaults.standard.bool(forKey: "jc_pending_voice")
                UserDefaults.standard.set(false, forKey: "jc_pending_voice")
                result(pending)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        NotificationCenter.default.removeObserver(
            self, name: Notification.Name("jcStartVoice"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fireStartVoiceIfPending),
            name: Notification.Name("jcStartVoice"), object: nil)
        fireStartVoiceIfPending()

        // Live Activity (Dynamic Island) start/stop, driven from Dart.
        let liveActivityChannel = FlutterMethodChannel(
            name: "jarviscopilot/liveactivity",
            binaryMessenger: controller.binaryMessenger
        )
        liveActivityChannel.setMethodCallHandler { (call, result) in
            if #available(iOS 16.2, *) {
                switch call.method {
                case "update":
                    LiveActivityManager.update((call.arguments as? [String: Any]) ?? [:])
                    result(true)
                case "end":
                    LiveActivityManager.end(); result(true)
                default: result(FlutterMethodNotImplemented)
                }
            } else {
                result(false)  // Live Activities need iOS 16.2+
            }
        }
        // Capture each activity's APNs push token and forward it to Dart (which
        // registers it with the server for push-to-update while suspended).
        if #available(iOS 16.2, *) {
            LiveActivityManager.channel = liveActivityChannel
            LiveActivityManager.startPushTokenObservation()
        }

        // Dynamic Island Designs: design-catalog cache channel. Dart syncs the
        // design catalog from the server and hands each design's layout-tree JSON
        // here; we write it into the shared App Group container so the JarvisWidget
        // extension (a SEPARATE process) can read `island/design-<id>.json` when
        // it renders a custom Live Activity. The ContentState only carries
        // {designId, version, data} — the tree itself is too big for the ~4KB cap.
        let islandChannel = FlutterMethodChannel(
            name: "jarviscopilot/island",
            binaryMessenger: controller.binaryMessenger
        )
        islandChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "cacheDesigns":
                let args = (call.arguments as? [String: Any]) ?? [:]
                let designs = (args["designs"] as? [[String: Any]]) ?? []
                result(IslandDesignCache.cache(designs))
            case "clearDesignCache":
                result(IslandDesignCache.clear())
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Direct-APNs push channel: native forwards the device token + silent
        // pushes to Dart (jarviscopilot/apnspush).
        AppDelegate.pushChannel = FlutterMethodChannel(
            name: "jarviscopilot/apnspush",
            binaryMessenger: controller.binaryMessenger)
        if let hex = AppDelegate.pendingApnsTokenHex {
            AppDelegate.pushChannel?.invokeMethod("apnsToken", arguments: ["token": hex])
        }

        // Permission-approval notification actions → Dart.
        AppDelegate.notifActionChannel = FlutterMethodChannel(
            name: "jarviscopilot/notification-actions",
            binaryMessenger: controller.binaryMessenger)
        if let pending = AppDelegate.pendingNotifAction {
            AppDelegate.pendingNotifAction = nil
            AppDelegate.notifActionChannel?.invokeMethod(
                "permissionAction", arguments: pending)
        }

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
        case "coding":
            // Coding Live Activity tap → just bring the app forward. (Switching
            // to the Coding tab in-app is a follow-up; the important thing here is
            // NOT to fall through to the pairing handler below.)
            break
        case "island":
            // Custom-design Live Activity tap → just bring the app forward (the
            // in-app Dynamic Island settings tab is a follow-up). Importantly, do
            // NOT fall through to the pairing handler below.
            break
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
            // SLC is already low-cost (cell-tower based); let iOS apply its power
            // heuristics rather than defeating them.
            m.pausesLocationUpdatesAutomatically = true
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
        // Nudge only — DON'T clear the flag here. Dart consumes it via
        // `consumePendingVoice`; if this nudge is lost on a cold launch (Dart's
        // handler not registered yet), the surviving flag lets Dart's startup
        // pull still pick it up.
        ch.invokeMethod("startVoice", arguments: nil)
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        super.applicationDidBecomeActive(application)
        fireStartVoiceIfPending()
    }

    // ── Direct APNs (no Firebase): token capture + silent-push wake ──────────
    // FirebaseAppDelegateProxyEnabled=NO (Info.plist) lets these AppDelegate
    // methods own push. The per-device APNs token + silent pushes go to Dart via
    // `pushChannel`; notification TAPS need no handler here — tapping foregrounds
    // the app, and the lifecycle `resumed` observer in main.dart drains the queue.
    static var pushChannel: FlutterMethodChannel?
    // The token can arrive before the Flutter channel is wired (registration is
    // async), so stash it and flush when the channel is set up.
    static var pendingApnsTokenHex: String?

    // Permission-approval notification actions → Dart (jarviscopilot/notification-actions).
    static var notifActionChannel: FlutterMethodChannel?
    // An action can fire before the channel is wired (app launched into the
    // background by the tap) — stash and flush once wired.
    static var pendingNotifAction: [String: Any]?

    // Handle a tapped notification action (Approve/Deny/Reply) — forward to Dart,
    // which POSTs the verdict. Works for the foreground/open case reliably; a
    // background action relies on the engine being alive (best-effort), with the
    // in-app approval card as the always-available fallback.
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let env = (info["jarviscopilot"] as? [String: Any]) ?? [:]
        var payload: [String: Any] = [
            "request_id": (env["request_id"] as? String) ?? "",
            "session_id": (env["session_id"] as? String) ?? "",
        ]
        switch response.actionIdentifier {
        case "APPROVE_PERMISSION": payload["action"] = "allow"
        case "DENY_PERMISSION": payload["action"] = "deny"
        case "REPLY_PERMISSION":
            payload["action"] = "reply"
            if let tr = response as? UNTextInputNotificationResponse {
                payload["text"] = tr.userText
            }
        default: payload["action"] = "open" // tapped the banner body
        }
        if let ch = AppDelegate.notifActionChannel {
            ch.invokeMethod("permissionAction", arguments: payload)
        } else {
            AppDelegate.pendingNotifAction = payload
        }
        completionHandler()
    }

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppDelegate.pendingApnsTokenHex = hex
        AppDelegate.pushChannel?.invokeMethod("apnsToken", arguments: ["token": hex])
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[push] APNs registration failed: \(error)")
    }

    // Silent (content-available) push → wake & drain the server's queued work,
    // completing when Dart replies (within the ~30s iOS background budget).
    override func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let ch = AppDelegate.pushChannel else {
            completionHandler(.noData); return
        }
        ch.invokeMethod("pushReceived", arguments: ["foreground": false]) { _ in
            completionHandler(.newData)
        }
    }
}

// ── Live Activity (Dynamic Island) ───────────────────────────────
//
// Starts/ends the minimal JARVIS Live Activity (rendered by JarvisLiveActivity
// in the JarvisWidget extension). Started while a voice session is active so the
// Dynamic Island shows "JARVIS"; ended when it stops.
@available(iOS 16.2, *)
enum LiveActivityManager {
    private static func contentState(_ args: [String: Any]) -> JarvisActivityAttributes.ContentState {
        // Online devices come from Dart (the server's /api/devices list). The
        // Apple Watch relays through the phone — it isn't a server-paired device —
        // so fold it in here from WCSession. Gate on paired + app installed, NOT
        // isReachable (which flaps off whenever the watch screen is down, so the
        // watch would almost never appear).
        var devices = (args["devices"] as? [String]) ?? []
        if WCSession.isSupported() {
            let wc = WCSession.default
            if wc.activationState == .activated,
               wc.isPaired, wc.isWatchAppInstalled,
               !devices.contains("watch") {
                devices.append("watch")
            }
        }
        // Safety clamp on strip width / payload (Dart already caps server devices
        // at 6; the watch can add one).
        if devices.count > 8 { devices = Array(devices.prefix(8)) }
        var sessions = (args["sessions"] as? [String]) ?? []
        if sessions.count > 4 { sessions = Array(sessions.prefix(4)) }
        return JarvisActivityAttributes.ContentState(
            state: (args["state"] as? String) ?? "idle",
            transcript: (args["transcript"] as? String) ?? "",
            activity: (args["activity"] as? String) ?? "",
            connected: (args["connected"] as? Bool) ?? true,
            devices: devices,
            mode: (args["mode"] as? String) ?? "voice",
            sessions: sessions,
            sessionTotal: (args["sessionTotal"] as? Int) ?? sessions.count,
            entryTotal: (args["entryTotal"] as? Int) ?? sessions.count,
            waitingCount: (args["waitingCount"] as? Int) ?? 0,
            usage5: (args["usage5"] as? Int) ?? -1,
            usageWeek: (args["usageWeek"] as? Int) ?? -1,
            usage5Resets: (args["usage5Resets"] as? String) ?? "",
            usageWeekResets: (args["usageWeekResets"] as? String) ?? "",
            // Custom-design fields (mode == "custom"). The layout tree itself is
            // cached on-device (see the jarviscopilot/island channel); only the
            // selector + live values ride in the ContentState.
            designId: (args["designId"] as? String) ?? "",
            designVersion: (args["designVersion"] as? Int) ?? 0,
            data: (args["data"] as? String) ?? ""
        )
    }

    /// Create the activity on the first ACTIVE state, or update the running one.
    /// Persists after a session (the app pushes an "idle" update on stop) —
    /// never auto-ends here, so it lingers as a tap-to-talk launcher.
    static func update(_ args: [String: Any]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Pre-download any remote image URLs bound into the pushed data payload
        // (e.g. an airline logo) so the widget can render them from the cache.
        IslandImageCache.prefetch(IslandImageCache.urls(inJSON: (args["data"] as? String) ?? ""))
        let state = contentState(args)
        let content = ActivityContent(state: state, staleDate: nil)
        if let existing = Activity<JarvisActivityAttributes>.activities.first {
            Task { await existing.update(content) }
        } else if (state.mode == "coding" && state.sessionTotal > 0)
                    || (state.mode == "custom" && !state.designId.isEmpty)
                    || state.state != "idle" {
            // Spin one up when something is happening: a live voice turn OR live
            // coding sessions OR a selected custom design (each an auto-launch
            // path — the activity appears without the user ever opening the Voice
            // screen).
            // Try to start WITH a push token (enables APNs push-to-update). If
            // the app isn't entitled for push — e.g. a free Apple account with no
            // Push Notifications capability — that request FAILS, so fall back to
            // a normal activity. Otherwise the Live Activity wouldn't appear at
            // all (foreground-driven updates still work without a token).
            let attrs = JarvisActivityAttributes(title: "JARVIS")
            do {
                let activity = try Activity.request(
                    attributes: attrs, content: content, pushType: .token)
                observe(activity)  // capture its APNs push token for push-to-update
            } catch {
                do {
                    _ = try Activity.request(attributes: attrs, content: content)
                } catch {
                    print("[LiveActivity] start failed: \(error)")
                }
            }
        }
    }

    static func end() {
        Task {
            for activity in Activity<JarvisActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // ── APNs push-to-update token capture ────────────────────────────────────
    static var channel: FlutterMethodChannel?
    private static var observedIds = Set<String>()

    /// Observe push tokens for every current + future activity and forward each
    /// to Dart as "laPushToken". The per-activity token is what APNs uses to
    /// push-to-update the Live Activity while the app is suspended/closed.
    static func startPushTokenObservation() {
        Task {
            for activity in Activity<JarvisActivityAttributes>.activities {
                observe(activity)
            }
            for await activity in Activity<JarvisActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }
    }

    fileprivate static func observe(_ activity: Activity<JarvisActivityAttributes>) {
        if observedIds.contains(activity.id) { return }
        observedIds.insert(activity.id)
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    channel?.invokeMethod("laPushToken", arguments: ["token": hex])
                }
            }
        }
    }
}

// ── Dynamic Island Designs: on-device design cache ───────────────
//
// The Live Activity ContentState (~4KB cap) can't carry a full layout tree, so
// designs are cached as JSON files in the shared App Group container. The Runner
// app writes them here (from Dart's catalog sync); the JarvisWidget extension —
// a SEPARATE process — reads `island/design-<id>.json` when it renders a custom
// design. Both targets must list the SAME App Group entitlement (see
// Runner.entitlements + JarvisWidget.entitlements) or containerURL returns nil.
enum IslandDesignCache {
    /// MUST match the App Group id in Runner.entitlements +
    /// JarvisWidget.entitlements and the constant in JarvisWidget.swift.
    static let appGroupId = "group.com.jarviscopilot.jarviscopilotMobileAndIOS"

    /// `<AppGroupContainer>/island/` — created on demand.
    private static func islandDir() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let dir = container.appendingPathComponent("island", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write each design's JSON string to `island/design-<id>.json`. Each entry:
    /// `{"id": String, "version": Int, "json": String}`. Returns true on success
    /// (best-effort — a single bad entry is skipped, not fatal).
    static func cache(_ designs: [[String: Any]]) -> Bool {
        guard let dir = islandDir() else { return false }
        for d in designs {
            guard let id = d["id"] as? String, !id.isEmpty,
                  let json = d["json"] as? String else { continue }
            // Keep the id filesystem-safe (catalog ids are slugs, but be defensive
            // so a crafted id can't escape the island dir).
            let safe = id.replacingOccurrences(
                of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
            let file = dir.appendingPathComponent("design-\(safe).json")
            try? json.data(using: .utf8)?.write(to: file, options: .atomic)
            // Pre-download any remote image URLs the design references so the
            // widget (which can't fetch at render time) renders them offline.
            IslandImageCache.prefetch(IslandImageCache.urls(inJSON: json))
        }
        return true
    }

    /// Remove the cached designs (the `island` dir contents). Returns true.
    static func clear() -> Bool {
        guard let dir = islandDir() else { return false }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        return true
    }
}

// Downloads remote island image URLs into the App Group so the widget extension
// (which cannot fetch at render time) can render them from disk, including
// offline once cached. Best-effort + idempotent: an already-cached URL is
// skipped, a failed download just leaves the leaf showing its fallback.
enum IslandImageCache {
    static let appGroupId = IslandDesignCache.appGroupId

    /// Deterministic filename for a URL. MUST match JCImageCache in JarvisWidget.swift.
    static func fileName(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func imagesDir() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let dir = container.appendingPathComponent("island/images", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Async-download any not-yet-cached http(s) image URLs.
    static func prefetch(_ urls: [String]) {
        guard let dir = imagesDir() else { return }
        let fm = FileManager.default
        for raw in Set(urls) {
            guard raw.hasPrefix("http"), let u = URL(string: raw) else { continue }
            let file = dir.appendingPathComponent(fileName(for: raw))
            if fm.fileExists(atPath: file.path) { continue }  // already cached
            URLSession.shared.dataTask(with: u) { data, _, _ in
                guard let data = data, !data.isEmpty,
                      UIImage(data: data) != nil else { return }
                try? data.write(to: file, options: .atomic)
            }.resume()
        }
    }

    /// Collect every http(s) URL string anywhere in a JSON-object string (used
    /// to harvest image `source` URLs from a design tree or a data payload).
    static func urls(inJSON jsonString: String) -> [String] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []
        func walk(_ v: Any) {
            if let s = v as? String {
                if s.hasPrefix("http://") || s.hasPrefix("https://") { out.append(s) }
            } else if let a = v as? [Any] {
                for e in a { walk(e) }
            } else if let m = v as? [String: Any] {
                for e in m.values { walk(e) }
            }
        }
        walk(obj)
        return out
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
