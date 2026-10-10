import Foundation

/// `/api/car` on the Jarvis server — the Toyota side of the Car page. The server talks to
/// Pranav's Home Assistant, which runs the Toyota integration; this never talks to Toyota.
struct ToyotaAPI: Sendable {
    var api: JarvisAPI
    /// For anything that acts on the car. The shared session waits up to an hour for a network,
    /// so a hold in a garage with no signal could unlock the car long after he walked away; this
    /// one fails at once without a network and gives up at `commandTimeout`.
    var actions: JarvisAPI
    static let prefix = "/api/car"
    /// Cloudflare drops a request at 100 s; the server answers by ~90 s (Toyota gets 75 s).
    static let commandTimeout: TimeInterval = 98

    init(api: JarvisAPI = .shared, actions: JarvisAPI? = nil) {
        self.api = api
        self.actions = actions ?? (api === JarvisAPI.shared ? Self.noWait : api)
    }

    private static let noWait: JarvisAPI = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = commandTimeout
        config.timeoutIntervalForResource = commandTimeout
        return JarvisAPI(transport: URLSessionTransport(session: URLSession(configuration: config)))
    }()

    /// No answer in time: the car may still be carrying the command out.
    struct Pending: LocalizedError {
        var errorDescription: String? { "No answer yet — check the car before trying again." }
    }

    /// A timeout or a gateway timeout means "unknown", not "failed".
    static func isPending(_ error: Error) -> Bool {
        if error is Pending { return true }
        if case .http(let status, _)? = error as? APIError { return status == 504 || status == 524 }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(ns.code)
    }

    struct State: Equatable {
        var account: ToyotaAccount
        var car: ToyotaCar?
        var error: String?
    }

    enum SignInStep: Equatable {
        case code(flowID: String)
        case done
    }

    func state() async throws -> State {
        let o = try await api.get(Self.prefix + "/state", timeout: 30).object()
        return State(account: ToyotaAccount(json: o["account"] as? [String: Any] ?? [:]),
                     car: (o["car"] as? [String: Any]).map(ToyotaCar.init(json:)),
                     error: o["error"] as? String)
    }

    /// Wakes the car for fresh status.
    func refresh() async throws {
        _ = try await actions.post(Self.prefix + "/refresh", timeout: Self.commandTimeout)
    }

    /// Runs a command after a completed tap-and-hold — with the Face ID proof for all but Stop.
    func run(_ command: ToyotaCommand, proof: ToyotaApprover.Proof?) async throws -> String {
        var body: [String: Any] = ["command": command.rawValue]
        if let proof { body.merge(["nonce": proof.nonce, "ts": proof.ts, "signature": proof.signature]) { $1 } }
        let o = try await actions.post(Self.prefix + "/command", json: body, timeout: Self.commandTimeout).object()
        guard o["ok"] as? Bool != false else {
            throw APIError.badResponse(o["error"] as? String ?? o["ask"] as? String ?? "the car didn't take it")
        }
        return o["result"] as? String ?? "Done"
    }

    func saveClimate(_ c: ToyotaCar.Climate) async throws -> ToyotaCar.Climate? {
        var body: [String: Any] = [:]
        if let custom = c.custom { body["custom"] = custom }
        if let temp = c.temp { body["temp"] = temp }
        if let front = c.defrostFront { body["defrost_front"] = front }
        if let rear = c.defrostRear { body["defrost_rear"] = rear }
        let o = try await actions.post(Self.prefix + "/climate", json: body, timeout: 60).object()
        return (o["climate"] as? [String: Any]).flatMap { ToyotaCar(json: ["climate": $0]).climate }
    }

    func signIn(email: String, password: String) async throws -> SignInStep {
        try step(try await api.post(Self.prefix + "/signin", json: ["email": email, "password": password],
                                    timeout: 90).object())
    }

    func submitCode(flowID: String, code: String) async throws -> SignInStep {
        try step(try await api.post(Self.prefix + "/signin/code", json: ["flow_id": flowID, "code": code],
                                    timeout: 90).object())
    }

    // MARK: Face ID approvals

    /// The public key the server checks signatures against; nil before any iPhone registered.
    func approverKey() async throws -> String? {
        let o = try await actions.get(Self.prefix + "/approver", timeout: 20).object()
        return o["public_key"] as? String
    }

    func registerApprover(publicKey: String, ts: Int, signature: String) async throws {
        _ = try await actions.post(Self.prefix + "/approver",
                                   json: ["public_key": publicKey, "ts": ts, "signature": signature], timeout: 20)
    }

    func approvals() async throws -> [CarApproval] {
        let o = try await api.get(Self.prefix + "/approvals", timeout: 20).object()
        return (o["approvals"] as? [[String: Any]] ?? []).compactMap(CarApproval.init(json:))
    }

    /// Answers Jarvis's request: the proof's nonce is the approval's id. Returns what the car did.
    func approve(_ approval: CarApproval, proof: ToyotaApprover.Proof) async throws -> String {
        let o = try await actions.post(Self.prefix + "/approvals/\(approval.id)/approve",
                                       json: ["ts": proof.ts, "signature": proof.signature],
                                       timeout: Self.commandTimeout).object()
        guard o["ok"] as? Bool != false else { throw APIError.badResponse(o["error"] as? String ?? "not done") }
        return o["result"] as? String ?? "Done"
    }

    func deny(_ approval: CarApproval) async throws {
        _ = try await api.post(Self.prefix + "/approvals/\(approval.id)/deny")
    }

    func signOut() async throws {
        _ = try await api.post(Self.prefix + "/signout")
    }

    private func step(_ o: [String: Any]) throws -> SignInStep {
        if o["step"] as? String == "code", let id = o["flow_id"] as? String { return .code(flowID: id) }
        if o["step"] as? String == "done" { return .done }
        throw APIError.badResponse("no sign-in step")
    }
}
