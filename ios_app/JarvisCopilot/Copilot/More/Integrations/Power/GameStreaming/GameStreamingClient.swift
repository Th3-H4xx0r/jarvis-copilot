import Foundation

// REST for Game Streaming (`/api/game-streaming`, webui/api/game_streaming_routes.py).
// A stream is client-initiated, so "start" readies the host and points a target's
// Moonlight at it; an asleep PC answers 202 (pending). Pair answers 409 while the
// PC is offline. Credentials are the server's; the Sunshine password never leaves
// the server.

/// The calls the card, page and store make — a protocol so the tests can pass a fake.
protocol GameStreamingAPI {
    func status() async throws -> GameStreamingStatus
    func start(target: String, game: String) async throws -> GameStartOutcome
    func stop(target: String?) async throws
    func pair(device: String, pin: String) async throws -> GamePairOutcome
    func unpair(device: String) async throws
}

struct GameStreamingClient: GameStreamingAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func status() async throws -> GameStreamingStatus {
        GameStreamingStatus(json: try await api.get("/api/game-streaming/status", timeout: 20).object())
    }

    func start(target: String, game: String) async throws -> GameStartOutcome {
        let res = try await api.post("/api/game-streaming/start", json: ["target": target, "game": game])
        if res.status == 202 { return .pending }
        let body = (try? res.object()) ?? [:]
        if body["status"] as? String == "pending" { return .pending }
        return .started(note: (body["note"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    func stop(target: String?) async throws {
        var body: [String: Any] = [:]
        if let target, !target.isEmpty { body["target"] = target }
        _ = try await api.post("/api/game-streaming/stop", json: body)
    }

    func pair(device: String, pin: String) async throws -> GamePairOutcome {
        do {
            let body = try await api.post("/api/game-streaming/pair",
                                          json: ["device": device, "pin": pin]).object()
            if body["ok"] as? Bool == true {
                return .paired(detail: (body["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            return .failed(body["error"] as? String ?? "Pairing didn't go through")
        } catch let APIError.http(status, message) where status == 409 {
            return .offline(message.isEmpty ? "The PC is asleep or offline" : message)
        }
    }

    func unpair(device: String) async throws {
        _ = try await api.post("/api/game-streaming/unpair", json: ["device": device])
    }
}
