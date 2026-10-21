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

    func setAskFacts(_ on: Bool) async throws -> IMessageMemoryCard {
        try await settings(["ask_facts": on])
    }

    func setPushFacts(_ on: Bool) async throws -> IMessageMemoryCard {
        try await settings(["push_facts": on])
    }

    // MARK: Fact cards

    /// The facts waiting for Store / Skip, newest first.
    func facts() async throws -> [IMessageFact] {
        try IMessageFact.decodeList(try await api.get("/api/imessage-memory/facts").data)
    }

    /// Store (or skip) these cards. Returns how many the server decided — an
    /// already-answered card counts as nothing, not as an error.
    @discardableResult
    func decide(ids: [String], store: Bool) async throws -> Int {
        try await decide(["ids": ids, "store": store])
    }

    /// Store (or skip) every card of one conversation — the push's "Store all" /
    /// "Skip all". `burst` is `"<guid>|<first_rowid>"`, as the push carries it.
    @discardableResult
    func decide(burst: String, store: Bool) async throws -> Int {
        try await decide(["burst": burst, "store": store])
    }

    private func decide(_ body: [String: Any]) async throws -> Int {
        let reply = try await api.post("/api/imessage-memory/facts/decide", json: body).object()
        return (reply["decided"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Preview

    /// The chat's last messages, read live from the Mac (oldest first). The server
    /// waits up to ~8 s for the Mac, then answers 504 with its own words.
    func preview(_ guid: String) async throws -> [IMessagePreviewMessage] {
        try IMessagePreviewMessage.decodeList(
            try await api.get("/api/imessage-memory/preview", query: ["guid": guid], timeout: Self.previewTimeout).data)
    }

    /// Longer than the server's own 8 s wait, so its answer (not ours) is what shows.
    static let previewTimeout: TimeInterval = 20

    private func settings(_ body: [String: Any]) async throws -> IMessageMemoryCard {
        try IMessageMemoryCard.decode(try await api.post("/api/imessage-memory/settings", json: body).data)
    }
}
