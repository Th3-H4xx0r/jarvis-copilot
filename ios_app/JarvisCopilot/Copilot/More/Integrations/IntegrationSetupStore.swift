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
    private var activeStreamID: String?

    init(api: ChatAPI = ChatAPI(), setupAPI: IntegrationsAPI = IntegrationsAPI()) {
        self.api = api
        self.setupAPI = setupAPI
    }

    deinit { streamTask.cancel() }

    var canSend: Bool { sessionID != nil && !streaming && finished == nil }
    /// The sheet could not open a session; the composer says so instead of eating
    /// what is typed into it.
    var needsRetry: Bool { sessionID == nil && !streaming }

    /// Anything created so far, so backing out can offer to undo it.
    var createdSpaceID: String? {
        if let id = finished?.spaceID, !id.isEmpty { return id }
        if let touched = turns.compactMap(\.spaceTouched).last { return touched }
        // integration_create names the space rather than passing an id; the server
        // slugs the name the same way, so this is the id it was given.
        return turns.flatMap(\.cards).last { $0.kind == .integration }
            .map { Self.slug($0.name) }
    }

    /// `jarvis_registry.store.slug`, so the sheet and the server agree on the id.
    nonisolated static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var pendingDash = false
        for character in lowered {
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(64))
    }

    func begin() async {
        guard sessionID == nil, !streaming else { return }
        streaming = true                       // no composer while the session opens
        do {
            sessionID = try await setupAPI.startSetup()
        } catch {
            errorMessage = apiErrorMessage(error)
            streaming = false
            return
        }
        streaming = false
        // The agent opens, so the sheet is never a blank box with a cursor.
        await send("Help me set up a new integration.", visible: false)
    }

    /// Run a send as the store's own task, so closing the sheet cancels it.
    func startSend(_ text: String) {
        streamTask.replace(Task { [weak self] in await self?.send(text) })
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
            activeStreamID = streamID
            for try await event in api.streamEvents(streamID) {
                if Task.isCancelled { break }      // the sheet closed under us
                apply(event, to: &reply)
                turns[turns.count - 1] = reply
            }
            activeStreamID = nil
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
    @discardableResult
    func discard() async -> Bool {
        guard let id = createdSpaceID, !id.isEmpty else { return true }
        // Everything, files included: the skill was written for this integration in
        // this conversation, so leaving it in service is not "delete what was created".
        var everything = IntegrationDeleteChoice()
        everything.skillFiles = true
        do {
            try await setupAPI.deleteParts(id, everything)
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    /// Stop the turn in flight. The agent creates as it goes, so a sheet that
    /// closes while it is still running goes on building — and "delete what was
    /// created" would race whatever it writes next.
    func close() async {
        streamTask.cancel()
        streaming = false
        guard let streamID = activeStreamID else { return }
        activeStreamID = nil
        _ = try? await api.cancel(streamID)
    }
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
    enum Kind: String, Sendable { case integration, data, schedule, skill }

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
        case "integration_create":
            // The first thing built, and the only one that names the space. Without
            // it the sheet cannot see what it has created, so backing out skips the
            // confirmation and leaves an empty integration behind.
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
        spaceID = MoreJSON.nonEmpty(args["space"]) ?? MoreJSON.nonEmpty(args["integration"])
            ?? MoreJSON.nonEmpty(args["id"])
        if name.isEmpty { return nil }
    }
}

struct SetupFinish: Equatable, Sendable {
    var spaceID: String
    var summary: String
}
