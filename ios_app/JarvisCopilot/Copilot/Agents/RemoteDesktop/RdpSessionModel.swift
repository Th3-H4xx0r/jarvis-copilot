import Foundation
import LocalAuthentication
import Observation
import UIKit

// MARK: - The flow (the same states as the web's RdpCore.flow)

enum RdpWarning: Equatable {
    /// A game is in front on the PC.
    case game(String)
    /// Someone used the PC's keyboard or mouse in the last two minutes while it was unlocked.
    case inUse
}

enum RdpFailure: Equatable {
    case asleep, offline, notReady, noPassword, edition
    case passwordRefused
    case notApproved
    case connectionLost
    case notInThisBuild
    case other(String)

    init(code: String, message: String?) {
        switch code {
        case "asleep": self = .asleep
        case "offline": self = .offline
        case "not_ready": self = .notReady
        case "no_password": self = .noPassword
        case "edition": self = .edition
        default: self = .other(message?.isEmpty == false ? message! : "Remote Desktop couldn't start")
        }
    }

    /// Whether to offer Wake (the PC sleeps).
    var offersWake: Bool { self == .asleep }
}

enum RdpState: Equatable {
    case idle
    case checking
    case warn(RdpWarning)
    case approving
    case connecting
    case connected
    case ended(String?)
    case error(RdpFailure)

    /// The web's state names (webui/static/rdp_core.js), for parity.
    var name: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .warn: return "warn"
        case .approving: return "approving"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .ended: return "ended"
        case .error: return "error"
        }
    }

    static let names = ["idle", "checking", "warn", "approving", "connecting", "connected", "ended", "error"]

    var isLive: Bool { self == .connecting || self == .connected }
}

enum RdpCopy {
    static func warning(_ w: RdpWarning, pc: String) -> (title: String, detail: String) {
        switch w {
        case .game(let name):
            return ("\(pc) is in a game", "\(name) is running. Connecting signs the PC's screen out; the game keeps running.")
        case .inUse:
            return ("Someone is using \(pc)", "It had keyboard or mouse input in the last two minutes. Connecting signs its screen out.")
        }
    }

    static func failure(_ f: RdpFailure, pc: String) -> String {
        switch f {
        case .asleep: return "\(pc) is asleep"
        case .offline: return "\(pc) is offline"
        case .notReady: return "Remote Desktop isn't set up on \(pc) yet — set it up in Jarvis on the PC (Settings → PC power)"
        case .noPassword: return "Save your Windows password in Jarvis on the PC first (Settings → PC power)"
        case .edition: return "\(pc) needs Windows 11 Pro for Remote Desktop"
        case .passwordRefused: return "Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)"
        case .notApproved: return "Not approved on your iPhone — nothing was released"
        case .connectionLost: return "The connection to \(pc) dropped"
        case .notInThisBuild: return "Remote Desktop isn't in this build of Jarvis yet"
        case .other(let m): return m
        }
    }
}

/// Reconnecting after a short drop (lock, network switch) reuses the in-memory password for 60 s;
/// later, a new session and a new Face ID.
enum RdpReconnect {
    static let window: TimeInterval = 60

    static func canReuse(droppedAt: Date?, now: Date = Date(), secret: RdpSecret?) -> Bool {
        guard let droppedAt, let secret, !secret.isWiped else { return false }
        return now.timeIntervalSince(droppedAt) <= window
    }
}

// MARK: - Server API (Task 1 routes, client "ios")

struct RdpSessionInfo: Equatable {
    let id: String
    let state: String
    let username: String
    let expiresAt: Date?
    /// The ciphertext frame once approved (never plaintext on iOS).
    let credential: [String: String]?

    init?(json: [String: Any]) {
        let s = (json["session"] as? [String: Any]) ?? json
        guard let id = s["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        state = s["state"] as? String ?? ""
        username = s["username"] as? String ?? ""
        expiresAt = (s["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        credential = (s["credential"] as? [String: Any])?.compactMapValues { $0 as? String }
    }
}

enum RdpCreateResult: Equatable {
    case warn(RdpWarning)
    case failure(RdpFailure)
    case session(RdpSessionInfo)

    /// `POST /api/rdp/sessions` → {warn,game_name} | {error,code} | {session}.
    static func parse(_ json: [String: Any]) -> RdpCreateResult {
        if let warn = json["warn"] as? String {
            if warn == "game" { return .warn(.game((json["game_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A game")) }
            return .warn(.inUse)
        }
        if let s = RdpSessionInfo(json: json), json["session"] != nil { return .session(s) }
        let code = json["code"] as? String ?? ""
        return .failure(RdpFailure(code: code, message: json["error"] as? String))
    }
}

protocol RdpServer {
    func create(deviceId: String, confirm: Bool, encPub: String) async throws -> RdpCreateResult
    func session(_ id: String) async throws -> RdpSessionInfo?
    func end(_ id: String) async
    func relayURL(_ id: String) throws -> URLRequest
}

struct RdpServerAPI: RdpServer {
    var api: JarvisAPI = .shared

    /// Read by hand: a warning or a refusal comes back as the body, whatever the status.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let req = try api.request(method, path, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: data,
                                  timeout: 20)
        let (bytes, http) = try await api.transport.send(req)
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:])
    }

    func create(deviceId: String, confirm: Bool, encPub: String) async throws -> RdpCreateResult {
        let (status, json) = try await call("POST", "/api/rdp/sessions",
                                            body: ["device_id": deviceId, "client": "ios", "confirm": confirm, "enc_pub": encPub])
        if status == 409, json["error"] != nil, json["code"] == nil {
            return .failure(.other("Remote Desktop is switched off (Integrations)"))
        }
        if status >= 500 { throw APIError.http(status: status, message: json["error"] as? String ?? "") }
        return RdpCreateResult.parse(json)
    }

    func session(_ id: String) async throws -> RdpSessionInfo? {
        let (status, json) = try await call("GET", "/api/rdp/sessions/\(id)")
        return status == 404 ? nil : RdpSessionInfo(json: json)
    }

    func end(_ id: String) async { _ = try? await call("DELETE", "/api/rdp/sessions/\(id)") }

    /// `wss://<host>/api/rdp/relay/<id>` with the paired device's headers.
    func relayURL(_ id: String) throws -> URLRequest {
        var req = try api.request("GET", "/api/rdp/relay/\(id)")
        if var c = req.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            c.scheme = c.scheme == "http" ? "ws" : "wss"
            req.url = c.url
        }
        return req
    }
}

// MARK: - Approval (the Unlock chain with kind "rdp": one Face ID approves and opens the key)

enum RdpApproval {
    /// Sessions whose approval the Remote Desktop screen shows itself: the generic Mac/PC
    /// password sheet skips their request, so there's one card and one Face ID.
    private static let inlineLock = NSLock()
    nonisolated(unsafe) private static var inline: Set<String> = []

    static func showInline(_ sessionId: String, _ on: Bool) {
        inlineLock.lock(); defer { inlineLock.unlock() }
        if on { inline.insert(sessionId) } else { inline.remove(sessionId) }
    }

    /// Whether the Remote Desktop screen is showing this request's approval.
    static func isInline(_ request: MacPasswordRequest) -> Bool {
        guard request.kind == "rdp" else { return false }
        inlineLock.lock(); defer { inlineLock.unlock() }
        return inline.contains { request.context.contains("\"\($0)\"") }
    }

    /// The PC's rdp request for this session, from the Agents list's password requests.
    static func request(for sessionId: String, in requests: [MacPasswordRequest]) -> MacPasswordRequest? {
        requests.first { $0.kind == "rdp" && $0.context.contains("\"\(sessionId)\"") }
    }

    /// Face ID ("Connect to …"), the signed yes, and the evaluated context to open the key with.
    static func allow(_ request: MacPasswordRequest, pc: String, api: AgentsAPI = AgentsAPI(),
                      signer: any CarSigner = SecureEnclaveCarSigner.shared) async throws -> LAContext? {
        let auth = try await signer.authenticate(reason: "Connect to \(pc)")
        let ts = Int(Date().timeIntervalSince1970)
        let signature = try await signer.sign(MacPasswordWire.message(kind: request.kind, nonce: request.nonce, ts: ts,
                                                                      context: request.context), auth: auth)
        try await api.macPasswordAnswer(id: request.id, decision: "allow", ts: ts, signature: signature.base64EncodedString())
        return auth.context
    }
}

// MARK: - The session

@Observable
@MainActor
final class RdpSessionModel {
    let deviceId: String
    let pcName: String

    private(set) var state: RdpState = .idle
    private(set) var sessionId: String?
    /// The live client (frames, input) once connecting.
    private(set) var client: RdpClient?
    /// Shown briefly over the session ("Copied from pranav-computer").
    var note: String?
    /// The PC's request for this session, waiting for Allow (the one Face ID).
    private(set) var approvalRequest: MacPasswordRequest?
    private(set) var approving = false

    @ObservationIgnored private let server: RdpServer
    @ObservationIgnored private let encPub: () throws -> Data
    @ObservationIgnored private let refreshRequests: () async -> [MacPasswordRequest]
    @ObservationIgnored private let answer: (MacPasswordRequest, Bool) async throws -> Void
    @ObservationIgnored private var approved = false
    @ObservationIgnored private var secret: RdpSecret?
    @ObservationIgnored private var username = ""
    @ObservationIgnored private var droppedAt: Date?
    @ObservationIgnored private var bridge: RdpLoopbackBridge?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var approvalTimeout: TimeInterval = 75
    @ObservationIgnored var pollInterval: UInt64 = 1_000_000_000
    @ObservationIgnored var desktopSize: (width: Int, height: Int) = (1280, 800)

    init(deviceId: String, pcName: String, server: RdpServer = RdpServerAPI(),
         encPub: @escaping () throws -> Data = { try RdpKey.shared.publicX963() },
         refreshRequests: (() async -> [MacPasswordRequest])? = nil,
         answer: ((MacPasswordRequest, Bool) async throws -> Void)? = nil) {
        self.deviceId = deviceId
        self.pcName = pcName
        self.server = server
        self.encPub = encPub
        let pc = pcName
        // Allow = the one Face ID (signs the yes); Deny needs none.
        self.answer = answer ?? { request, allow in
            if allow { _ = try await RdpApproval.allow(request, pc: pc) }
            else { try await MacPasswordApproval.deny(request, api: AgentsAPI()) }
        }
        self.refreshRequests = refreshRequests ?? {
            await AgentsStore.shared.refresh()
            return AgentsStore.shared.passwordRequests
        }
    }

    /// Tap on Remote Desktop (or "Connect anyway" after a warning).
    func start(confirm: Bool = false) {
        task?.cancel()
        task = Task { await run(confirm: confirm) }
    }

    func run(confirm: Bool) async {
        state = .checking
        do {
            let pub = try encPub().base64EncodedString()
            switch try await server.create(deviceId: deviceId, confirm: confirm, encPub: pub) {
            case .warn(let w): state = .warn(w)
            case .failure(let f): state = .error(f)
            case .session(let s):
                sessionId = s.id
                username = s.username
                state = .approving
                await waitForApproval(s.id)
            }
        } catch {
            if !wasCancelled(error) { state = .error(.other(apiErrorMessage(error))) }
        }
    }

    private func waitForApproval(_ id: String) async {
        let deadline = Date().addingTimeInterval(approvalTimeout)
        approved = false
        RdpApproval.showInline(id, true)
        defer { RdpApproval.showInline(id, false) }
        var tries = 0
        while !Task.isCancelled, Date() < deadline {
            // The PC's request shows here as the approval card; Allow is the only Face ID.
            if !approved, approvalRequest == nil, tries % 2 == 0,
               let request = RdpApproval.request(for: id, in: await refreshRequests()) {
                approvalRequest = request
            }
            tries += 1
            do {
                if let s = try await server.session(id) {
                    if !s.username.isEmpty { username = s.username }
                    if s.state == "approved", let credential = s.credential {
                        await open(credential, sessionId: id)
                        return
                    }
                    if s.state == "cancelled" || s.state == "ended" { state = .error(.notApproved); return }
                } else if tries > 2 {            // the server forgot it (expired, switched off)
                    state = .error(.notApproved)
                    return
                }
            } catch {
                // A dropped poll: try again next tick.
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        if !Task.isCancelled {
            await server.end(id)
            state = .error(.notApproved)
        }
    }

    /// Allow on the approval card: Face ID once, the signed yes goes to the PC.
    func allow() async {
        guard let request = approvalRequest, !approving else { return }
        approving = true
        defer { approving = false }
        do {
            try await answer(request, true)
            approved = true
            approvalRequest = nil
        } catch {
            if (error as? CarSignError) == .cancelled { return }   // he cancelled Face ID: the card stays
            state = .error(.other("Couldn't approve: \(apiErrorMessage(error))"))
        }
    }

    /// Deny on the approval card (no Face ID): nothing is released.
    func deny() async {
        if let request = approvalRequest { try? await answer(request, false) }
        approvalRequest = nil
        cancel()
    }

    private func open(_ credential: [String: String], sessionId: String) async {
        state = .connecting
        do {
            let p = try RdpEcies.parts(credential)
            // No Face ID here: the key needs none (the approval was the one Face ID).
            let password = try RdpCredentials.open(ciphertext: p.ciphertext, ephemeralPub: p.ephemeral, nonce: p.nonce)
            secret = RdpSecret(password)
            try await connect(sessionId: sessionId)
        } catch {
            state = .error(.other("Couldn't open the password from \(pcName): \(error.localizedDescription)"))
            await server.end(sessionId)
        }
    }

    /// Opens the relay through a loopback port and points FreeRDP at it.
    private func connect(sessionId: String) async throws {
        guard let secret else { throw RdpCredentialError.badCredential }
        let bridge = RdpLoopbackBridge(request: try server.relayURL(sessionId))
        self.bridge = bridge
        let port = try await bridge.start()
        let client = RdpClient()
        self.client = client
        client.onState = { [weak self] state, failure in self?.clientChanged(state, failure) }
        client.onClipboard = { [weak self] text in
            UIPasteboard.general.string = text
            self?.note = "Copied from \(self?.pcName ?? "the PC")"
        }
        try client.connect(host: "127.0.0.1", port: Int(port), username: username, secret: secret,
                           width: desktopSize.width, height: desktopSize.height,
                           drivePath: RdpTransfers.folder.path)
    }

    private func clientChanged(_ state: RdpClient.State, _ failure: RdpFailure?) {
        switch state {
        case .connecting: self.state = .connecting
        case .connected:
            self.state = .connected
            droppedAt = nil
        case .ended:
            bridge?.close()
            bridge = nil
            if let failure {
                if failure == .connectionLost { droppedAt = Date() }
                self.state = .error(failure)
                if failure == .passwordRefused { endEverything() }
            } else if self.state != .ended(nil) {
                self.state = .ended(nil)
                endEverything()
            }
        }
    }

    /// After a short drop: the same session's relay with the password still in memory (60 s);
    /// past that, a new session and a new Face ID.
    func reconnect() {
        guard let id = sessionId, RdpReconnect.canReuse(droppedAt: droppedAt, secret: secret) else {
            endEverything()
            start(confirm: true)
            return
        }
        state = .connecting
        task = Task {
            do { try await connect(sessionId: id) } catch {
                endEverything()
                start(confirm: true)
            }
        }
    }

    func disconnect() {
        client?.disconnect()
        state = .ended(nil)
        endEverything()
    }

    /// Cancel on the warning or the approval: nothing connects.
    func cancel() {
        task?.cancel()
        if let id = sessionId { Task { await server.end(id) } }
        sessionId = nil
        state = .idle
    }

    private func endEverything() {
        task?.cancel()
        bridge?.close()
        bridge = nil
        secret?.wipe()
        secret = nil
        approvalRequest = nil
        if let id = sessionId { Task { [server] in await server.end(id) } }
        sessionId = nil
    }

    /// Tests and rendered previews: show a state, or a client already connected.
    func preview(state: RdpState, client: RdpClient? = nil) {
        self.state = state
        if let client { self.client = client }
    }

    /// Wake through the Agents card's server path (it works while the PC sleeps).
    func wake() async -> String? {
        await ComputerPowerRunner.run(.wake, deviceID: deviceId).contains("unavailable") ? "Couldn't wake \(pcName)" : nil
    }
}

/// Opens Remote Desktop from anywhere (the card, the Tools list, a button): the root presents it.
@Observable
@MainActor
final class RdpPresenter {
    static let shared = RdpPresenter()
    var model: RdpSessionModel?

    func open(deviceId: String, name: String) {
        if let model, model.deviceId == deviceId, model.state.isLive { return }
        let m = RdpSessionModel(deviceId: deviceId, pcName: name)
        // The session starts at this phone's size (× up to 2) and follows rotation after.
        let bounds = UIScreen.main.bounds.size
        let px = min(UIScreen.main.scale, 2)
        m.desktopSize = (Int(bounds.width * px) & ~1, Int((bounds.height - 120) * px))
        model = m
        m.start()
    }
}
