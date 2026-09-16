import Foundation
import Observation

/// What the setup sheet knows that an ordinary chat does not.
///
/// The conversation itself is a `ChatStore` like any other — this only opens the
/// scoped session, watches the transcript for the tools that build an
/// integration, and can take back what was built if the user changes their mind.
@Observable
@MainActor
final class IntegrationSetupStore {
    private let api: IntegrationsAPI

    private(set) var errorMessage: String?
    /// Set when the agent calls `integration_ready`. The composer becomes Close.
    private(set) var finished: SetupFinish?
    /// The space the conversation made, so backing out can offer to undo it.
    private(set) var createdSpaceID: String?

    init(api: IntegrationsAPI = IntegrationsAPI()) { self.api = api }

    /// Opens a session pinned to this job. Returns its id, or nil if it could not.
    func begin() async -> String? {
        do {
            errorMessage = nil
            return try await api.startSetup()
        } catch {
            errorMessage = apiErrorMessage(error)
            return nil
        }
    }

    /// Read the transcript for the two things this screen cares about: which space
    /// is being built, and whether the agent has said it is done.
    func noticeReady(in messages: [ChatMessage]) {
        for message in messages {
            for tool in message.tools {
                if let space = SetupCard(toolName: tool.name, args: tool.args)?.spaceID {
                    createdSpaceID = space
                }
                guard tool.name == "integration_ready", tool.done else { continue }
                let space = Self.spaceID(inResultOf: tool) ?? createdSpaceID ?? ""
                if !space.isEmpty { createdSpaceID = space }
                finished = SetupFinish(spaceID: space, summary: "")
            }
        }
    }

    /// Remove what the conversation built. Offered when backing out half-way,
    /// because by then the pieces are real rather than proposed.
    @discardableResult
    func discard() async -> Bool {
        guard let id = createdSpaceID, !id.isEmpty else { return true }
        // Everything, files included: the skill was written for this integration in
        // this conversation, so leaving it in service is not "delete what was created".
        var everything = IntegrationDeleteChoice()
        everything.skillFiles = true
        do {
            try await api.deleteParts(id, everything)
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    /// `{"ok": true, "space": "gym-sessions", …}` — the id the tool confirmed.
    nonisolated static func spaceID(inResultOf tool: ToolInvocation) -> String? {
        for text in [tool.result, tool.preview].compactMap({ $0 }) {
            guard let range = text.range(of: "\"space\"") else { continue }
            let tail = text[range.upperBound...]
            guard let open = tail.firstIndex(of: "\""),
                  case let start = tail.index(after: open),
                  let close = tail[start...].firstIndex(of: "\"") else { continue }
            let value = String(tail[start..<close])
            if !value.isEmpty { return value }
        }
        return nil
    }
}

struct SetupFinish: Equatable, Sendable {
    var spaceID: String
    var summary: String
}

/// A piece of an integration, as the agent creates it.
///
/// Built from the tool call that made it, so the chat can draw it as the thing it
/// is rather than as a row of JSON. The tools that only read do not earn a card.
struct SetupCard: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case integration, data, schedule, skill }

    let id = UUID()
    var kind: Kind
    var name: String
    var detail: String
    var spaceID: String?

    init?(toolName: String, args: [String: JSONValue]) {
        let text: (String) -> String = { args[$0]?.displayText ?? "" }
        switch toolName {
        case "integration_create":
            kind = .integration
            name = text("name")
            detail = text("description")
        case "registry_append", "registry_describe":
            let collection = text("collection")
            guard !collection.isEmpty else { return nil }
            kind = .data
            name = collection
            detail = text("description")
        case "registry_put":
            let key = text("key")
            guard !key.isEmpty else { return nil }
            kind = .data
            name = key
            detail = text("description")
        case "cronjob":
            // One tool, many actions; only a new schedule is something created.
            guard text("action") == "create" else { return nil }
            kind = .schedule
            name = text("name")
            detail = text("schedule")
        case "skill_manage":
            guard text("action") == "create" else { return nil }
            kind = .skill
            name = text("name")
            detail = text("category")
        default:
            return nil
        }
        spaceID = [text("space"), text("integration"), text("id")].first { !$0.isEmpty }
        if kind == .integration, spaceID == nil, !name.isEmpty {
            // integration_create names the space; the server slugs that name.
            spaceID = Self.slug(name)
        }
        if name.isEmpty { return nil }
    }

    /// `jarvis_registry.store.slug`, so the app and the server agree on the id.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(64))
    }
}
