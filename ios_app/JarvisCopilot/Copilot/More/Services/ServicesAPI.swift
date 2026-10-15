import Foundation

/// REST for the Services and Portfolio screens (`/api/services/*`, served by
/// `webui/api/services_routes.py`). No endpoint ever returns a secret, and the
/// phone only ever sends the ones you typed.
struct ServicesAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    struct Overview {
        let services: [ServiceSnapshot]
        /// Configured services whose first poll hasn't come back yet.
        let pending: [String]
    }

    /// `GET /api/services` → `{services, pending, ts}`.
    func overview() async throws -> Overview {
        let body = try await api.get("/api/services").object()
        return Overview(services: CodingJSON.maps(body["services"]).map(ServiceSnapshot.init(json:)),
                        pending: CodingJSON.strings(body["pending"]))
    }

    /// `GET /api/services/<id>/detail` (the server re-reads it when older than a minute).
    func detail(_ id: String) async throws -> ServiceDetail {
        ServiceDetail(json: try await api.get("/api/services/\(id)/detail").object())
    }

    /// `POST /api/services/<id>/action`. 409 and 502 are answers here, not
    /// errors: they carry why it wasn't done (or the question to ask first) and
    /// the detail as it stands, which `JarvisAPI.post` would throw away. Anything
    /// else that isn't 2xx (400, 404, an edge proxy's HTML page) still throws.
    func action(_ id: String, kind: String, target: String, confirmed: Bool,
                requestedAt: Date) async throws -> ServiceActionReply {
        let body: [String: Any] = ["kind": kind, "target": target, "confirmed": confirmed,
                                   "requested_at": requestedAt.timeIntervalSince1970]
        let request = try api.request("POST", "/api/services/\(id)/action",
                                      headers: ["Content-Type": "application/json"],
                                      body: try JSONSerialization.data(withJSONObject: body))
        let (data, http) = try await api.transport.send(request)
        let status = http.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status) {
            guard let json else { throw APIError.badResponse("not JSON") }
            return ServiceActionReply(status: status, json: json)
        }
        if status == 409 || status == 502, let json, json["detail"] != nil || json["result"] != nil {
            return ServiceActionReply(status: status, json: json)
        }
        throw APIError.http(status: status, message: APIError.message(status: status, body: data))
    }

    // MARK: config

    /// `GET /api/services/config` — `has_key` booleans, never a key.
    func config() async throws -> ServicesConfig {
        ServicesConfig(json: try await api.get("/api/services/config").object())
    }

    /// `POST /api/services/config` with one of `{service, secrets?, settings?}`,
    /// `{exchange, secrets}` or `{crypto}`. Answers with the whole config again.
    func saveConfig(_ body: [String: Any]) async throws -> ServicesConfig {
        ServicesConfig(json: try await api.post("/api/services/config", json: body).object())
    }

    // MARK: portfolio

    struct Portfolio {
        let crypto: CryptoBoard?
        let portfolio: PortfolioBoard?
    }

    /// `GET /api/services/portfolio` → `{crypto, portfolio, ts}` (either may be null).
    func portfolio() async throws -> Portfolio {
        let body = try await api.get("/api/services/portfolio").object()
        return Portfolio(crypto: CryptoBoard(json: body["crypto"]), portfolio: PortfolioBoard(json: body["portfolio"]))
    }

    /// `POST /api/services/portfolio/wallets {op: "add", network, address, label}`.
    /// The server checks the address format and reads it once before keeping it.
    func addWallet(network: String, address: String, label: String) async throws -> [WalletEntry] {
        let body = try await api.post("/api/services/portfolio/wallets",
                                      json: ["op": "add", "network": network, "address": address,
                                             "label": label]).object()
        return WalletEntry.list(body["wallets"])
    }

    /// `POST /api/services/portfolio/wallets {op: "remove", network, address}`.
    func removeWallet(network: String, address: String) async throws -> [WalletEntry] {
        let body = try await api.post("/api/services/portfolio/wallets",
                                      json: ["op": "remove", "network": network, "address": address]).object()
        return WalletEntry.list(body["wallets"])
    }
}
