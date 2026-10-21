import Foundation

/// Client for `/api/imessage-memory` — the same endpoints the web Integrations page uses.
/// Every settings change answers with the whole card, so the screen never guesses.
struct IMessageMemoryAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func card() async throws -> IMessageMemoryCard {
        try IMessageMemoryCard.decode(try await api.get("/api/imessage-memory").data)
    }

    func setEnabled(_ enabled: Bool) async throws -> IMessageMemoryCard {
        try await settings(["enabled": enabled])
    }

    func setAgent(_ choice: AgentChoice?) async throws -> IMessageMemoryCard {
        try await settings(["agent": IMessageMemoryAgent(choice).json])
    }

    func setSkip(_ people: [IMessagePerson]) async throws -> IMessageMemoryCard {
        try await settings(["skip": people.map(\.json)])
    }

    /// `pick`: true / false, or nil to follow the default again.
    func setPick(_ guid: String, pick: Bool?) async throws -> IMessageMemoryCard {
        let body: [String: Any] = ["guid": guid, "pick": pick.map { $0 as Any } ?? NSNull()]
        return try IMessageMemoryCard.decode(try await api.post("/api/imessage-memory/chat", json: body).data)
    }

    /// Deletes every memory that came from one chat. Returns how many went.
    func forget(_ guid: String) async throws -> Int {
        let body = try await api.post("/api/imessage-memory/forget", json: ["guid": guid]).object()
        return (body["forgotten"] as? NSNumber)?.intValue ?? 0
    }

    /// `chats` nil = every ticked chat.
    func backfill(from: Date, to: Date, chats: [String]?) async throws {
        var body: [String: Any] = ["from": from.timeIntervalSince1970, "to": to.timeIntervalSince1970]
        if let chats { body["chats"] = chats }
        _ = try await api.post("/api/imessage-memory/backfill", json: body)
    }

    func stop(_ jobID: String) async throws {
        _ = try await api.post("/api/imessage-memory/backfill/stop", json: ["id": jobID])
    }

    private func settings(_ body: [String: Any]) async throws -> IMessageMemoryCard {
        try IMessageMemoryCard.decode(try await api.post("/api/imessage-memory/settings", json: body).data)
    }
}
