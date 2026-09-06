import Foundation
import Combine

/// Talks to JarvisCopilot's device bridge.
///
/// The protocol is JarvisCopilot's, documented at the top of
/// `webui/api/device_bridge.py`:
///
///     server → device   {"type":"hello","device_id":"…"}
///     device → server   {"type":"register","skills":[{name,description,input_schema}]}
///     server → device   {"type":"invoke","call_id":"…","skill":"…","args":{…}}
///     device → server   {"type":"result","call_id":"…","result":{…}}
///                  or   {"type":"error","call_id":"…","error":"…"}
///     either            {"type":"ping"} / {"type":"pong"}
///
/// Pairing mints a `hermes_session` cookie via `POST /api/auth/pair/claim`, which may
/// also hand back a Cloudflare Access service token for the tunnel.
@MainActor
final class BridgeClient: NSObject, ObservableObject {
    static let shared = BridgeClient()

    enum Status: Equatable {
        case off, pairing, connecting, online, failed(String)

        var text: String {
            switch self {
            case .off:           return "Not connected"
            case .pairing:       return "Pairing…"
            case .connecting:    return "Connecting…"
            case .online:        return "Online"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var registeredSkills = 0
    @Published private(set) var lastActivity: Date?
    /// When a silent push last woke us, and what came of it. Persisted so it survives
    /// the app being suspended and relaunched — otherwise there's no way to tell a
    /// push that never arrived from one that arrived and failed.
    var lastPushAt: Date? {
        get { UserDefaults.standard.object(forKey: "bridgeLastPushAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeLastPushAt") }
    }
    var lastPushOutcome: String {
        get { UserDefaults.standard.string(forKey: "bridgeLastPushOutcome") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeLastPushOutcome") }
    }

    /// Server base URL, e.g. `https://jarvis.example.com`. Stored in the Keychain with
    /// the rest of the pairing: UserDefaults is erased when the app is deleted, which
    /// left a reinstall holding a session cookie it had no server to use it against.
    var serverURL: String {
        get { Keychain.read("bridgeServerURL") ?? "" }
        set { Keychain.write("bridgeServerURL", newValue); objectWillChange.send() }
    }
    /// Keeps the BLE link (and this socket) alive when the app backgrounds.
    /// ON by default: Jarvis has to reach the phone and its wearables whenever
    /// they are around, not only while the app is open. The Settings switch
    /// ("Stay connected in background") turns it off explicitly.
    var enabled: Bool {
        get { Keychain.read("bridgeEnabled") != "0" }
        set {
            Keychain.write("bridgeEnabled", newValue ? "1" : "0")
            syncKeepalive()
            objectWillChange.send()
        }
    }

    /// The silent-audio keepalive runs exactly when bridge mode could deliver
    /// something: on, and paired. Without it the app is suspended on background and
    /// every invoke has to go through the silent push.
    private func syncKeepalive() {
        BackgroundKeepalive.shared.sync(active: enabled && isPaired)
    }

    /// Start the keepalive at launch when bridge mode is on — the setter only
    /// syncs on a change, so a fresh launch used to run without it.
    func syncKeepaliveNow() { syncKeepalive() }

    // MARK: Per-device exposure

    /// Whether a given wearable may be advertised to Jarvis. Keyed by the device's own
    /// stable id, so the choice survives reconnects and app launches. Defaults to on:
    /// bridge mode is the master switch, and this is for excluding a device from it.
    static func isExposed(_ deviceID: String) -> Bool {
        UserDefaults.standard.object(forKey: "jarvisExposed.\(deviceID)") as? Bool ?? true
    }

    static func setExposed(_ exposed: Bool, for deviceID: String) {
        UserDefaults.standard.set(exposed, forKey: "jarvisExposed.\(deviceID)")
    }

    /// Devices the user has opted in, as `[deviceID: model]`. Kept separately from the
    /// live registry so settings can list a shared bottle that's simply out of range,
    /// rather than showing nothing.
    static var sharedRecords: [String: String] {
        UserDefaults.standard.dictionary(forKey: "jarvisSharedDevices") as? [String: String] ?? [:]
    }

    static func remember(deviceID: String, model: String) {
        var records = sharedRecords
        guard records[deviceID] != model else { return }
        records[deviceID] = model
        UserDefaults.standard.set(records, forKey: "jarvisSharedDevices")
    }

    static func forget(deviceID: String) {
        var records = sharedRecords
        guard records.removeValue(forKey: deviceID) != nil else { return }
        UserDefaults.standard.set(records, forKey: "jarvisSharedDevices")
    }

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?

    /// All bridge traffic goes through this rather than `URLSession.shared`.
    ///
    /// The default session accepts and persists cookies, which would (a) write the
    /// `hermes_session` credential into the on-disk cookie jar, outside the Keychain
    /// protection we chose for it, and (b) attach it automatically *in addition* to the
    /// `Cookie` header we set explicitly, sending it twice. Ephemeral + cookies off
    /// means the only credential on the wire is the one we put there.
    private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    private var pingTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pollTask: Task<Void, Never>?

    private override init() { super.init() }

    // MARK: Credentials

    private var sessionCookie: String? {
        get { Keychain.read("bridgeSessionCookie") }
        set { Keychain.write("bridgeSessionCookie", newValue) }
    }
    private var cfClientID: String? {
        get { Keychain.read("bridgeCFClientID") }
        set { Keychain.write("bridgeCFClientID", newValue) }
    }
    private var cfClientSecret: String? {
        get { Keychain.read("bridgeCFClientSecret") }
        set { Keychain.write("bridgeCFClientSecret", newValue) }
    }

    var isPaired: Bool { sessionCookie?.isEmpty == false }

    /// Applies credentials carried in a pairing QR. Stored before the claim so the
    /// claim request itself can clear Cloudflare Access.
    func applyScanned(cfClientID id: String?, cfClientSecret secret: String?) {
        if let id, !id.isEmpty { cfClientID = id }
        if let secret, !secret.isEmpty { cfClientSecret = secret }
    }

    func unpair() {
        disconnect()
        sessionCookie = nil
        cfClientID = nil
        cfClientSecret = nil
        Keychain.write("bridgeServerURL", nil)
        Keychain.write("bridgeEnabled", nil)
        syncKeepalive()
        status = .off
    }

    /// A request against the paired server carrying the session cookie and, when the
    /// tunnel needs one, the Cloudflare service token. Nil when no server URL is set.
    func authorizedRequest(path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 60) -> URLRequest? {
        guard let base = baseURL(),
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// The cookie-free session every bridge call goes through.
    var urlSession: URLSession { http }

    /// For `JarvisAPI` (Copilot port): the paired server and the auth headers.
    /// Nonisolated (Keychain reads are thread-safe) so background actors can call them.
    nonisolated func apiBaseURL() -> URL? {
        var text = (Keychain.read("bridgeServerURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
    nonisolated func apiAuthHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let cookie = Keychain.read("bridgeSessionCookie"), !cookie.isEmpty { h["Cookie"] = "hermes_session=\(cookie)" }
        if let id = Keychain.read("bridgeCFClientID"), let secret = Keychain.read("bridgeCFClientSecret"), !id.isEmpty, !secret.isEmpty {
            h["CF-Access-Client-Id"] = id
            h["CF-Access-Client-Secret"] = secret
        }
        return h
    }

    /// The Cloudflare Access service token the tunnel handed us at pairing, for handing
    /// on to a board that will make its own requests through the same tunnel.
    var cfAccessToken: (id: String, secret: String)? {
        guard let id = cfClientID, let secret = cfClientSecret, !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }

    private func baseURL() -> URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// Session cookie plus, when the server handed us one at pairing, the Cloudflare
    /// Access service token its tunnel requires for non-browser clients.
    private func authHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let cookie = sessionCookie { h["Cookie"] = "hermes_session=\(cookie)" }
        if let id = cfClientID, let secret = cfClientSecret {
            h["CF-Access-Client-Id"] = id
            h["CF-Access-Client-Secret"] = secret
        }
        return h
    }

    // MARK: Pairing

    /// Claims a pairing code from JarvisCopilot and stores the resulting session.
    func pair(code: String) async throws {
        guard let base = baseURL() else {
            throw BridgeError.message("Set the server URL first")
        }
        status = .pairing

        var request = URLRequest(url: base.appendingPathComponent("api/auth/pair/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Carries a Cloudflare service token if one is already stored, so re-pairing
        // against an Access-protected tunnel still clears the edge.
        for (k, v) in authHeaders() where k.hasPrefix("CF-") {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code.trimmingCharacters(in: .whitespaces),
            "name": deviceLabel(),
        ])

        let (data, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.message("No response")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200 else {
            status = .failed("pairing rejected")
            throw BridgeError.message(body["error"] as? String ?? "Pairing failed (\(http.statusCode))")
        }

        // The session arrives as a Set-Cookie; the server never returns it in the body.
        guard let cookie = Self.sessionCookie(from: http, url: base) else {
            status = .failed("no session cookie")
            throw BridgeError.message("Server did not return a session cookie")
        }
        sessionCookie = cookie

        if let cf = body["cf_access"] as? [String: Any] {
            cfClientID = cf["client_id"] as? String
            cfClientSecret = cf["client_secret"] as? String
        }

        // Marks the device `mobile-ios` server-side, which is what enables the queue
        // fallback used while we're backgrounded.
        try? await announcePlatform()

        enabled = true
        connect()
        #if canImport(UIKit)
        PushService.shared.registerIfPaired()
        #endif
    }

    private static func sessionCookie(from response: HTTPURLResponse, url: URL) -> String? {
        let fields = response.allHeaderFields as? [String: String] ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        return cookies.first { $0.name == "hermes_session" }?.value
    }

    /// The app's `aps-environment`, read from the embedded provisioning profile rather
    /// than hardcoded — a token minted under a development entitlement is only valid
    /// against APNs sandbox, and this build's environment can change the moment it's
    /// signed for distribution.
    static var apsEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded",
                                        withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              // The profile is CMS-signed; the plist sits between these markers.
              let start = text.range(of: "<plist"),
              let end = text.range(of: "</plist>") else { return "development" }
        let plist = String(text[start.lowerBound..<end.upperBound])
        guard let data = plist.data(using: .isoLatin1),
              let parsed = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else {
            return "development"
        }
        return env
    }

    /// Registers the APNs token so the server can wake us with a silent push when it
    /// has a command queued. `push_kind: "apns"` is what flips `_invoke_via_mobile_push`
    /// from "no push token" to actually sending one.
    func registerPush(token: String) async {
        guard isPaired else { return }
        _ = try? await postJSON(path: "api/devices/mobile/token", body: [
            "platform": "ios",
            "push_kind": "apns",
            "push_token": token,
            // The APNs topic is the bundle ID. Without this the server would push
            // with its configured default (the Flutter client's) and we'd never
            // receive anything.
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.jarviscopilot.jarviscopilotMobileAndIOS",
            // Lets the server pick the APNs host per device, so it can stay on
            // production for other clients regardless of how this build is signed.
            "push_env": Self.apsEnvironment,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ])
    }

    private func announcePlatform() async throws {
        _ = try await postJSON(path: "api/devices/mobile/token", body: [
            "platform": "ios",
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.jarviscopilot.jarviscopilotMobileAndIOS",
            // Lets the server pick the APNs host per device, so it can stay on
            // production for other clients regardless of how this build is signed.
            "push_env": Self.apsEnvironment,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ])
    }

    private func deviceLabel() -> String {
        #if canImport(UIKit)
        return "JarvisCopilot (iPhone)"
        #else
        return "JarvisCopilot (Mac)"
        #endif
    }

    // MARK: Connection

    func connect() {
        syncKeepalive()
        guard enabled, isPaired, let base = baseURL() else { return }
        guard socket == nil else { return }

        var components = URLComponents(url: base.appendingPathComponent("api/devices/bridge/ws"),
                                       resolvingAgainstBaseURL: false)
        components?.scheme = (base.scheme == "http") ? "ws" : "wss"
        guard let wsURL = components?.url else { return }

        status = .connecting
        var request = URLRequest(url: wsURL)
        for (k, v) in authHeaders() { request.setValue(v, forHTTPHeaderField: k) }

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive()
        startPings()
    }

    func disconnect() {
        pingTask?.cancel(); pingTask = nil
        pollTask?.cancel(); pollTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if case .failed = status {} else { status = .off }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error.localizedDescription)
                case .success(let message):
                    self.lastActivity = Date()
                    if case .string(let text) = message { self.handle(text) }
                    else if case .data(let d) = message,
                            let text = String(data: d, encoding: .utf8) { self.handle(text) }
                    self.receive()
                }
            }
        }
    }

    private func handleDrop(_ reason: String) {
        socket = nil
        pingTask?.cancel(); pingTask = nil
        guard enabled, isPaired else { status = .off; return }
        status = .failed(reason)
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = UInt64(pow(2.0, Double(reconnectAttempt))) * 1_000_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.connect()
        }
    }

    // MARK: Protocol

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = msg["type"] as? String else { return }

        switch type {
        case "hello":
            reconnectAttempt = 0
            status = .online
            sendRegistration()
        case "registered":
            registeredSkills = msg["count"] as? Int ?? 0
        case "invoke":
            Task { await self.runInvoke(msg) }
        case "ping":
            send(["type": "pong"])
        default:
            break   // forward-compat: ignore unknown types
        }
    }

    func sendRegistration() {
        let skills = DeviceRegistry.shared.allSkills()
        send(["type": "register", "skills": skills])
    }

    private func runInvoke(_ msg: [String: Any]) async {
        guard let callID = msg["call_id"] as? String,
              let skill = msg["skill"] as? String else { return }
        let args = msg["args"] as? [String: Any] ?? [:]
        do {
            let result = try await DeviceRegistry.shared.invoke(skill: skill, args: args)
            send(["type": "result", "call_id": callID, "result": result])
        } catch {
            send(["type": "error", "call_id": callID, "error": error.localizedDescription])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.handleDrop(error.localizedDescription) }
        }
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                self?.send(["type": "ping"])
            }
        }
    }

    // MARK: Background queue

    /// While backgrounded the socket won't survive, so drain whatever the bridge
    /// queued for us instead. Mirrors the Flutter client's `push_handler.dart`.
    func drainQueue(foreground: Bool) async {
        // Deliberately not gated on `enabled`: bridge mode governs whether we *hold*
        // the Bluetooth link open, not whether we answer the server. A silent push
        // means work is queued, and refusing to drain it is why invokes timed out.
        guard isPaired else {
            note("woke but not paired")
            return
        }
        guard let body = try? await postJSON(path: "api/devices/mobile/poll",
                                             body: ["foreground": foreground]),
              let invokes = body["invokes"] as? [[String: Any]] else {
            note("poll failed")
            return
        }
        guard !invokes.isEmpty else {
            note("woke, queue empty")
            return
        }
        note("running \(invokes.count) command(s)")

        for item in invokes {
            guard let callID = item["call_id"] as? String,
                  let skill = item["skill"] as? String else { continue }
            let args = item["args"] as? [String: Any] ?? [:]
            do {
                let result = try await DeviceRegistry.shared.invoke(skill: skill, args: args)
                _ = try? await postJSON(path: "api/devices/mobile/result",
                                        body: ["call_id": callID, "result": result])
            } catch {
                _ = try? await postJSON(path: "api/devices/mobile/result",
                                        body: ["call_id": callID,
                                               "error": error.localizedDescription])
            }
        }
        lastActivity = Date()
        note("delivered \(invokes.count) result(s)")
    }

    /// Records what happened on a wake, so Settings can show whether pushes are even
    /// arriving — the difference between "APNs isn't delivering" and "delivery worked
    /// but the bottle was unreachable".
    private func note(_ outcome: String) {
        lastPushAt = Date()
        lastPushOutcome = outcome
        objectWillChange.send()
    }

    @discardableResult
    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let base = baseURL() else { throw BridgeError.message("No server URL") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// Minimal Keychain wrapper — the session cookie and Cloudflare service token are
/// credentials and don't belong in UserDefaults.
enum Keychain {
    private static let service = "com.jarviscopilot.jarviscopilotMobileAndIOS.bridge"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Match both synced and local items, so pairings written before the
            // switch to iCloud Keychain are still found.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // AfterFirstUnlock so a silent push can read it while the phone is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // Rides iCloud Keychain, so the pairing survives deleting and reinstalling
            // the app — and follows the user to a replacement phone.
            kSecAttrSynchronizable as String: true,
        ]
        add[kSecAttrDescription as String] = "Jarvis Copilot pairing"
        SecItemAdd(add as CFDictionary, nil)
    }
}
