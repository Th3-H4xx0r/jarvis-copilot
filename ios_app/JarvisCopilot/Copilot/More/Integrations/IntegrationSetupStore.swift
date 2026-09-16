import Foundation
import Observation

/// The conversation behind the + button.
///
/// A session pinned to one job — building a single integration — talking to the
/// real agent over the ordinary chat stream. Follow-up questions are just its
/// turns. Each piece is created as it is settled, and the tools it calls become
/// the "created" cards the sheet shows, so the user watches it being built.
///
/// It is finished when the agent calls `integration_ready`; nothing else ends it.
@Observable
@MainActor
final class IntegrationSetupStore {
    private let api: ChatAPI
    private let setupAPI: IntegrationsAPI
    private let streamTask = TaskHandle()

    private(set) var sessionID: String?
    private(set) var turns: [SetupTurn] = []
    private(set) var streaming = false
    private(set) var errorMessage: String?
    /// Set when the agent says the integration is built. The composer becomes Close.
    private(set) var finished: SetupFinish?

    init(api: ChatAPI = ChatAPI(), setupAPI: IntegrationsAPI = IntegrationsAPI()) {
        self.api = api
        self.setupAPI = setupAPI
    }

    deinit { streamTask.cancel() }

    var canSend: Bool { !streaming && finished == nil }

    /// Anything created so far, so backing out can offer to undo it.
    var createdSpaceID: String? {
        finished?.spaceID ?? turns.compactMap(\.spaceTouched).last
    }

    func begin() async {
        guard sessionID == nil else { return }
        do {
            sessionID = try await setupAPI.startSetup()
        } catch {
            errorMessage = apiErrorMessage(error)
            return
        }
        // The agent opens, so the sheet is never a blank box with a cursor.
        await send("Help me set up a new integration.", visible: false)
    }

    func send(_ text: String, visible: Bool = true) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !trimmed.isEmpty, canSend else { return }
        if visible { turns.append(SetupTurn(role: .user, text: trimmed)) }
        streaming = true
        errorMessage = nil
        var reply = SetupTurn(role: .assistant, text: "")
        turns.append(reply)

        do {
            let started = try await api.startMessage(sessionID: sessionID, text: trimmed)
            guard let streamID = started["stream_id"] as? String else {
                throw APIError.badResponse("the server did not start a turn")
            }
            for try await event in api.streamEvents(streamID) {
                apply(event, to: &reply)
                turns[turns.count - 1] = reply
            }
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        if reply.isEmpty { turns.removeLast() }
        streaming = false
    }

    private func apply(_ event: SSEEvent, to reply: inout SetupTurn) {
        switch event.event {
        case "token", "delta", "text":
            reply.text += event.string("delta") ?? event.string("text")
                ?? event.string("content") ?? ""
        case "tool", "tool_start", "tool_call":
            if let card = SetupCard(toolName: event.string("name") ?? "",
                                    args: JSONValue(event["args"] ?? event["input"]).objectValue ?? [:]) {
                reply.cards.append(card)
            }
        case "tool_complete", "tool_end":
            if let name = event.string("name"), name == "integration_ready" {
                finished = SetupFinish(spaceID: event.string("space") ?? createdSpaceID ?? "",
                                       summary: event.string("summary") ?? "")
            }
        case "error", "apperror":
            errorMessage = event.string("error") ?? event.string("message") ?? "Something went wrong."
        default:
            break
        }
    }

    /// Remove what the conversation built. Offered when backing out half-way,
    /// because by then the pieces are real rather than proposed.
    func discard() async {
        guard let id = createdSpaceID, !id.isEmpty else { return }
        _ = try? await setupAPI.deleteParts(id, IntegrationDeleteChoice())
    }

    func cancelStream() { streamTask.cancel() }
}

/// One side of the setup conversation, plus whatever it created along the way.
struct SetupTurn: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    var role: Role
    var text: String
    var cards: [SetupCard] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cards.isEmpty
    }

    /// The space this turn touched, if its tools named one.
    var spaceTouched: String? {
        cards.compactMap(\.spaceID).last
    }
}

/// A piece of the integration, as it is created.
struct SetupCard: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case data, schedule, skill }

    let id = UUID()
    var kind: Kind
    var name: String
    var detail: String
    var spaceID: String?

    /// The tools that build an integration, read as the thing they built. Anything
    /// else the agent calls is plumbing and does not earn a card.
    init?(toolName: String, args: JSONObject) {
        let text: (String) -> String = { MoreJSON.text(args[$0]) }
        switch toolName {
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
        spaceID = MoreJSON.nonEmpty(args["space"]) ?? MoreJSON.nonEmpty(args["integration"])
        if name.isEmpty { return nil }
    }
}

struct SetupFinish: Equatable, Sendable {
    var spaceID: String
    var summary: String
}
