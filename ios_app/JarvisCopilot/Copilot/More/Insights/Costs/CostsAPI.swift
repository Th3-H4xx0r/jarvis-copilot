import Foundation

/// REST wrapper for Insights → Costs (`webui/api/costs_routes.py`).
///
/// Every mutation throws the server's `{error}` text as an `APIError.http`, so
/// a sheet can show "That doesn't look like a valid Admin API key." verbatim.
struct CostsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// The collector can run for up to ~45 s before the server stops waiting.
    static let collectTimeout: TimeInterval = 75

    /// `GET /api/costs?days=N`.
    func overview(days: Int) async throws -> CostsOverview {
        CostsOverview(json: try await api.get("/api/costs", query: ["days": "\(days)"]).object())
    }

    /// `GET /api/costs/service?id=X&days=N`.
    func service(_ id: String, days: Int) async throws -> CostServiceDetail {
        CostServiceDetail(json: try await api.get("/api/costs/service",
                                                  query: ["id": id, "days": "\(days)"]).object())
    }

    /// Save billing-API keys and sync that service. With `days`, the reply also
    /// carries the service's detail for that window, so the sheet needn't
    /// fetch it again.
    func connect(_ id: String, fields: [String: String], days: Int? = nil) async throws -> CostConnectReply {
        var request: JSONObject = ["service": id, "fields": fields]
        if let days { request["days"] = days }
        let body = try await api.post("/api/costs/connect", json: request, timeout: Self.collectTimeout).object()
        return CostConnectReply(json: body)
    }

    /// Remove the billing-only keys this page added. History and the plan
    /// price stay.
    func disconnect(_ id: String) async throws {
        _ = try await api.post("/api/costs/disconnect", json: ["service": id] as JSONObject)
    }

    /// A plan price for a service; nil `amount` clears it.
    func setSubscription(_ id: String, amount: Double?, interval: String, plan: String?) async throws {
        var body: JSONObject = ["service": id, "interval": interval,
                                "amount_usd": amount.map { $0 as Any } ?? NSNull()]
        if let plan, !plan.isEmpty { body["plan"] = plan }
        _ = try await api.post("/api/costs/subscription", json: body)
    }

    /// A custom subscription (a VPS, a domain…). Returns the new service id.
    func addSubscription(name: String, amount: Double, interval: String) async throws -> String {
        let body = try await api.post("/api/costs/subscription",
                                      json: ["name": name, "amount_usd": amount,
                                             "interval": interval] as JSONObject).object()
        return MoreJSON.text(body["service"])
    }

    /// The monthly budget; nil clears it.
    func setBudget(_ monthly: Double?) async throws {
        _ = try await api.post("/api/costs/budget",
                               json: ["monthly_usd": monthly.map { $0 as Any } ?? NSNull()] as JSONObject)
    }

    /// Run the collector now (one service, or all of them).
    func refresh(_ id: String? = nil) async throws {
        var body: JSONObject = [:]
        if let id { body["service"] = id }
        _ = try await api.post("/api/costs/refresh", json: body, timeout: Self.collectTimeout)
    }
}

/// `POST /api/costs/connect`'s reply: what the sync did, and the service's
/// fresh detail when the request named a window.
struct CostConnectReply: Equatable, Sendable {
    var result: CostConnectResult
    var detail: CostServiceDetail?

    init(json: JSONObject) {
        result = CostConnectResult(json: json)
        let raw = MoreJSON.map(json["detail"])
        let parsed = CostServiceDetail(json: raw)
        detail = raw.isEmpty || parsed.service.id.isEmpty ? nil : parsed
    }
}

/// What `POST /api/costs/connect` did after saving the keys.
enum CostConnectResult: Equatable, Sendable {
    /// The provider answered; billing is live.
    case connected
    /// The sync couldn't run yet (another run holds the lock); it will.
    case pending
    /// Saved, but no sync result came back (the collector failed, or the
    /// service has no billing API to call) — so nothing says it works yet.
    case saved
    /// Saved, but the provider rejected the sync (or a key is still missing).
    case syncFailed(String)

    init(json: JSONObject) {
        let sync = MoreJSON.map(json["sync"])
        if MoreJSON.isFalse(sync["ok"]) {
            self = .syncFailed(MoreJSON.nonEmpty(sync["error"]) ?? "unknown error")
        } else if MoreJSON.isTrue(json["pending"]) {
            self = .pending
        } else if MoreJSON.isTrue(sync["ok"]) {
            self = .connected
        } else {
            // A null `sync` used to read as "Connected" — a key nobody checked.
            self = .saved
        }
    }

    /// The line under the form.
    var message: String {
        switch self {
        case .connected: return "Connected"
        case .pending: return "Saved, syncing now"
        case .saved: return "Saved"
        case .syncFailed(let error): return "Saved, but the sync failed: \(error)"
        }
    }

    var failed: Bool { if case .syncFailed = self { return true } else { return false } }
}
