import Foundation
import Observation

/// One open session screen's data: the session in full (its steps and last
/// turn, `GET /api/coding/agents/session?key=`) and, when the session has a
/// Coding row, its Claude Code transcript (`GET /api/coding/session/<id>/messages`).
///
/// Push-driven like the rest of the tab: the screen reloads when the `agents`
/// topic reports something new for this session (`lastEventAt` moves), and the
/// topic only flows while the tab is on screen — so nothing here polls. Unlike
/// the Coding tab's `CodingSessionStore` it never attaches the terminal: the
/// transcript is read-only and instructions go through `/agents/instruction`.
@MainActor
@Observable
final class AgentSessionModel {
    let key: String

    private(set) var detail: AgentSessionDetail?
    private(set) var detailLoaded = false
    private(set) var error: String?
    private(set) var transcript = CodingTranscript()

    @ObservationIgnored private let agents: AgentsAPI
    @ObservationIgnored private let coding: CodingSessionsAPI
    /// The Coding row the transcript belongs to; a new one starts it over.
    @ObservationIgnored private var transcriptId: String?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false

    init(key: String, agents: AgentsAPI = AgentsAPI(), coding: CodingSessionsAPI? = nil) {
        self.key = key
        self.agents = agents
        self.coding = coding ?? CodingSessionsAPI(api: agents.api)
    }

    /// The session's detail, then its transcript tail. A call that lands while
    /// one runs is folded into one more pass, so a burst of pushes costs two
    /// fetches, not one per push.
    func load(codingSessionId: String?) async {
        if loading { again = true; return }
        loading = true
        defer { loading = false }
        repeat {
            again = false
            await loadDetail()
            if let id = codingSessionId ?? detail?.item.codingSessionId {
                await loadTranscript(id)
            }
        } while again
    }

    private func loadDetail() async {
        do {
            detail = try await agents.session(key: key)
            error = nil
        } catch {
            // A blip keeps what's on screen; only a first failure says so.
            if detail == nil && !wasCancelled(error) { self.error = apiErrorMessage(error) }
        }
        detailLoaded = true
    }

    private func loadTranscript(_ id: String) async {
        if transcriptId != id {
            transcriptId = id
            transcript = CodingTranscript()
        }
        var full = transcript.messages.isEmpty
        for _ in 0..<2 {
            do {
                let page = try await coding.chatMessages(id, after: CodingStreamReducer.cursor(transcript, full: full))
                if case .needsFullReload = CodingStreamReducer.apply(page, full: full, to: &transcript) {
                    full = true
                    continue
                }
                return
            } catch {
                if wasCancelled(error) { return }
                CodingStreamReducer.applyFetchFailure(error, to: &transcript)
                return
            }
        }
    }

    // MARK: what the screen draws

    func choice(codingSessionId: String?) -> AgentTranscriptChoice {
        AgentTranscriptChoice.choose(codingSessionId: codingSessionId ?? detail?.item.codingSessionId,
                                     transcript: transcript, turn: detail?.turn, detailLoaded: detailLoaded)
    }

    func items(codingSessionId: String?, working: Bool) -> [AgentConversationItem] {
        switch choice(codingSessionId: codingSessionId) {
        case .transcript:
            return AgentConversation.collapse(AgentConversation.items(transcript.messages, working: working))
        case .lastTurn:
            guard let turn = detail?.turn else { return [] }
            return AgentConversation.collapse(AgentConversation.items(turn, working: working))
        case .loading, .empty:
            return []
        }
    }
}
