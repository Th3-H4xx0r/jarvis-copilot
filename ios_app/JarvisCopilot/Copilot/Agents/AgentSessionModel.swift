import Foundation
import Observation

/// One open session screen's data: the conversation's full transcript from the
/// server's copy (`GET /api/coding/agents/messages?ckey=`), paged from the end,
/// and — for an agent the server keeps no transcript for — its own record of
/// the last turn (`GET /api/coding/agents/session?key=`).
///
/// Push-driven like the rest of the tab: the screen reloads when the
/// `agents_list` push moves this conversation's `lastEventAt`, and the topic
/// only flows while the tab is on screen — so nothing here polls.
@MainActor
@Observable
final class AgentSessionModel {
    let ckey: String

    private(set) var transcript = CodingTranscript()
    /// The agent's own last turn, when there's no transcript to show.
    private(set) var turn: AgentTurn?
    private(set) var detailLoaded = false
    private(set) var error: String?
    /// The page above is on its way.
    private(set) var loadingOlder = false
    /// Messages loaded in full (by index) when you opened a tool or a diff.
    private(set) var details: [Int: CodingChatMessage] = [:]
    /// Messages the server could only send lite: their rows don't open.
    private(set) var noDetails: Set<Int> = []
    @ObservationIgnored private var loadingDetails = Set<Int>()

    @ObservationIgnored private let agents: AgentsAPI
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var again = false

    init(ckey: String, agents: AgentsAPI = AgentsAPI()) {
        self.ckey = ckey
        self.agents = agents
    }

    /// The transcript's tail, then (only without one) the last turn. A call
    /// that lands while one runs is folded into one more pass, so a burst of
    /// pushes costs two fetches, not one per push.
    func load(key: String?) async {
        if loading { again = true; return }
        loading = true
        defer { loading = false }
        repeat {
            again = false
            await loadTranscript()
            if transcript.messages.isEmpty, let key, !key.isEmpty {
                await loadTurn(key)
            } else {
                detailLoaded = true
            }
        } while again
    }

    private func loadTranscript() async {
        var full = transcript.messages.isEmpty
        for _ in 0..<2 {
            do {
                let page = try await agents.messages(ckey: ckey,
                                                     after: CodingStreamReducer.cursor(transcript, full: full),
                                                     limit: CodingStreamReducer.limit(transcript, paged: true))
                if case .needsFullReload = CodingStreamReducer.apply(page, full: full, to: &transcript) {
                    full = true
                    continue
                }
                error = nil
                return
            } catch {
                if wasCancelled(error) { return }
                CodingStreamReducer.applyFetchFailure(error, to: &transcript)
                if transcript.messages.isEmpty { self.error = apiErrorMessage(error) }
                return
            }
        }
    }

    private func loadTurn(_ key: String) async {
        do {
            turn = try await agents.session(key: key).turn
        } catch {
            // A blip keeps what's on screen.
        }
        detailLoaded = true
    }

    /// The page above what's on screen (the user scrolled to the top).
    func loadOlder() async {
        guard !loadingOlder, transcript.hasOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await agents.messages(ckey: ckey, before: CodingStreamReducer.before(transcript),
                                                 limit: CodingStreamReducer.pageSize)
            _ = CodingStreamReducer.applyOlder(page, to: &transcript)
        } catch {
            // A blip: the row stays, and scrolling back to it tries again.
        }
    }

    /// One message in full: what a tool printed, a file's diff (the chat list
    /// comes without them). Loaded when you open one.
    func loadDetails(_ i: Int) async {
        guard !loadingDetails.contains(i), !noDetails.contains(i) else { return }
        loadingDetails.insert(i)
        defer { loadingDetails.remove(i) }
        do {
            let page = try await agents.messages(ckey: ckey, before: i + 1, limit: 1, lite: false)
            guard let m = page.messages.first(where: { $0.i == i }) else { return }
            if Self.stillLite(m) {
                noDetails.insert(i)
            } else {
                details[i] = m
            }
        } catch {
            // A blip: the row stays closed-over; opening it again retries.
        }
    }

    /// A server that only sends lite pages answers a detail fetch lite too.
    static func stillLite(_ m: CodingChatMessage) -> Bool {
        !m.tools.isEmpty && m.tools.allSatisfy { t in
            (t.more && t.output.isEmpty) || (t.diff.isEmpty && t.diffCounts != nil)
        }
    }

    // MARK: what the screen draws

    func choice() -> AgentTranscriptChoice {
        AgentTranscriptChoice.choose(transcriptId: ckey, transcript: transcript, turn: turn,
                                     detailLoaded: detailLoaded)
    }

    func items(working: Bool) -> [AgentConversationItem] {
        switch choice() {
        case .transcript:
            let messages = AgentConversation.withDetails(transcript.messages, details)
            return AgentConversation.collapse(AgentConversation.items(messages, working: working,
                                                                     noDetails: noDetails))
        case .lastTurn:
            guard let turn else { return [] }
            return AgentConversation.collapse(AgentConversation.items(turn, working: working))
        case .loading, .empty, .copying:
            return []
        }
    }
}
