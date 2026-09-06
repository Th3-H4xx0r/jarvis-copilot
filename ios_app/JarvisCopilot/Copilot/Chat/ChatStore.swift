import Foundation
import Observation

// MARK: - Store

/// Drives the native chat screen. Owns the sessions list, the active session's
/// messages, and the live streaming turn. Ported from `chat/chat_controller.dart`,
/// with the stream resilience of this app's `Esp32ChatStore` folded in.
///
/// The streaming model mirrors the web UI: `POST /api/chat/start` starts a run and
/// SSE frames fold into the trailing assistant message (see ``ChatStreamReducer``).
/// Two things make that unreliable on a phone, and both are handled here:
///
/// * The server's per-turn event queue is **single-consumer**. If the web UI is
///   open on the same session it drains the queue and our socket goes quiet
///   without closing, so `idleLimit` seconds of silence means "snapshot the
///   session and re-attach", not "the turn failed".
/// * Starting a turn on a session that already has one running answers **409**.
///   That is usually *our own* previous turn whose stream broke, so we attach to
///   it rather than reporting a failure or double-submitting.
@Observable
@MainActor
final class ChatStore {

    // MARK: Dependencies

    @ObservationIgnored private let chatAPI: ChatAPI
    @ObservationIgnored private let sessionsAPI: SessionsAPI
    @ObservationIgnored private let modelsAPI: ModelsAPI
    @ObservationIgnored private let selection: ModelSelection
    @ObservationIgnored private let clock: ChatClock
    @ObservationIgnored private let clipboard: ChatClipboard
    /// Internal, not private: `ChatEntryPoints.swift` reports whether the
    /// local-first lane is wired at all, and Swift's `private` is file-scoped.
    @ObservationIgnored let onDevice: OnDeviceChatHandler?
    @ObservationIgnored private let resilience: ChatResilience

    // MARK: Sessions

    /// Newest first, archived rows removed.
    var sessions: [ChatSessionSummary] = []
    var sessionsLoading = false

    // MARK: Active session

    var sessionID: String?
    var sessionTitle = "New chat"
    /// Written only through ``setMessages(_:)`` and the private mutators, so
    /// ``rows`` can never drift out of step with it.
    private(set) var messages: [ChatMessage] = []
    /// The transcript with the speaker-grouping the layout needs, kept in step
    /// with ``messages`` instead of rebuilt on every `body` evaluation — that ran
    /// once per streamed token on the whole thread (swift-correctness H9).
    private(set) var rows: [ChatRow] = []
    /// Bumped on every transcript change. The scroll-to-bottom hook watches this
    /// rather than `messages`, whose `onChange` deep-compares the entire thread
    /// per token.
    private(set) var messagesTick = 0
    var historyLoading = false

    // MARK: Streaming turn

    var streaming = false
    /// A screen-level error (list/history failures). A failed *turn* shows in its
    /// own bubble instead.
    var error: String?
    /// The agent's open clarify question; answering it resumes the blocked turn.
    var pendingClarify: ClarifyPrompt?

    /// Live usage from `metering` frames, for the composer's subtle readout.
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCost: Double?

    // MARK: Composer

    var pendingAttachments: [ChatPendingAttachment] = []
    /// A transient pick error (oversize, unreadable) the composer can show.
    var attachError: String?

    // MARK: Models

    var models: ModelCatalog?
    /// nil means "whatever the server's default is".
    private(set) var selectedModelID: String?
    private(set) var selectedProviderID: String?

    // MARK: Private turn bookkeeping

    @ObservationIgnored private var liveMessageID: UUID?
    @ObservationIgnored private var liveStreamID: String?
    @ObservationIgnored private var turnStartedAt = Date()
    @ObservationIgnored private var lastPublishedClarify: ClarifyPrompt?
    /// Consecutive failed background list refreshes. A quiet poll that has been
    /// failing for a while is not "quiet", it is broken (silent-failures M20).
    @ObservationIgnored private var quietListFailures = 0
    /// ``TaskHandle`` keeps a finished task in the box, so "is a task installed"
    /// cannot answer "is the poll still running" — this can (swift-correctness M26).
    @ObservationIgnored private var pollRunning = false
    @ObservationIgnored private var pollEpoch = 0
    @ObservationIgnored private let turnHandle = TaskHandle()
    @ObservationIgnored private let syncHandle = TaskHandle()
    @ObservationIgnored private let pollHandle = TaskHandle()

    init(api: JarvisAPI = .shared,
         selection: ModelSelection = .shared,
         bus: ChatSyncBus = .shared,
         clock: ChatClock = SystemChatClock(),
         clipboard: ChatClipboard = SystemChatClipboard(),
         onDevice: OnDeviceChatHandler? = nil,
         resilience: ChatResilience = ChatResilience()) {
        chatAPI = ChatAPI(api: api)
        sessionsAPI = SessionsAPI(api: api)
        modelsAPI = ModelsAPI(api: api)
        self.selection = selection
        self.clock = clock
        self.clipboard = clipboard
        self.onDevice = onDevice
        self.resilience = resilience
        selectedModelID = selection.model(for: .chat)
        selectedProviderID = selection.provider(for: .chat)

        // Live chats: refresh when a turn is added elsewhere (e.g. a voice
        // conversation persists to a session). See ``ChatSyncBus``.
        syncHandle.replace(Task { [weak self] in
            for await changed in bus.changes() {
                await self?.sessionChangedElsewhere(changed)
            }
        })
    }

    /// `deinit` is nonisolated, which is exactly why the tasks live in
    /// ``TaskHandle``s (immutable `Sendable let`s) rather than plain vars.
    deinit {
        syncHandle.cancel()
        pollHandle.cancel()
        turnHandle.cancel()
    }

    // MARK: Derived state the view reads

    var hasSession: Bool { !(sessionID ?? "").isEmpty }
    var isEmpty: Bool { messages.isEmpty && !historyLoading }

    /// Whether the sessions-list poll is armed.
    var listPolling: Bool { pollRunning }

    var selectedModel: ChatModel? { models?.models.first { $0.id == selectedModelID } }

    func canSend(draft: String) -> Bool {
        guard !streaming else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    // MARK: Sessions list

    /// Reload the sessions list. `quiet` skips the spinner and swallows errors —
    /// for background refreshes (the sync signal, tab focus, the visible-tab poll)
    /// so they never flash a spinner or stomp the error bar.
    func loadSessions(quiet: Bool = false) async {
        if !quiet { sessionsLoading = true }
        do {
            sessions = try await sessionsAPI.list()
                .filter { !$0.archived && !$0.id.isEmpty }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            quietListFailures = 0
        } catch {
            let line = apiErrorMessage(error)
            if quiet {
                // One quiet failure is a blip; a run of them means the list on
                // screen is stale and the user has no way to know.
                quietListFailures += 1
                if quietListFailures >= Self.quietFailureLimit {
                    self.error = "Chats may be out of date: \(line)"
                }
            } else {
                self.error = "Could not load chats: \(line)"
            }
        }
        if !quiet { sessionsLoading = false }
    }

    /// Consecutive quiet failures before the error bar is allowed to speak.
    static let quietFailureLimit = 3

    /// Called when the chat tab becomes visible (or the app resumes): pull the
    /// latest list and open thread so anything added while we were away shows up.
    func refreshOnFocus() async {
        await loadSessions(quiet: true)
        await refreshActiveQuietly()
    }

    /// Re-fetch the open thread and re-hydrate it without the clear/reload flash.
    /// A no-op while streaming, loading, or sessionless — never clobber a live turn.
    func refreshActiveQuietly() async {
        guard let id = sessionID, !id.isEmpty, !streaming, !historyLoading else { return }
        let detail: ChatSessionDetail
        do { detail = try await sessionsAPI.get(id) } catch {
            // Deliberately silent on screen — this runs on every focus — but never
            // silent in the log (silent-failures L7).
            JcLog.dropped(JcLog.chat, "quiet session refresh", error)
            return
        }
        guard id == sessionID, !streaming else { return }   // changed under us mid-fetch
        if !detail.title.isEmpty { sessionTitle = detail.title }
        setMessages(detail.messages)
    }

    /// Poll the sessions LIST (cheap: previews and ordering) while the chat tab is
    /// visible, so it stays live. The open thread is refreshed on focus and on sync
    /// signals — not polled — to avoid scroll and flicker mid-read.
    func setListPolling(_ on: Bool) {
        guard on else {
            pollEpoch &+= 1
            pollRunning = false
            pollHandle.cancel()
            return
        }
        guard !pollRunning else { return }
        pollEpoch &+= 1
        let epoch = pollEpoch
        pollRunning = true
        let clock = self.clock
        pollHandle.replace(Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: 6) } catch { break }
                guard let self else { return }
                if !streaming { await loadSessions(quiet: true) }
            }
            // A loop that ends on its own (a clock that stopped sleeping) has to
            // say so, or the next `setListPolling(true)` sees a task in the handle
            // and never re-arms.
            await self?.listPollingStopped(epoch)
        })
    }

    private func listPollingStopped(_ epoch: Int) {
        guard epoch == pollEpoch else { return }   // a newer poll already took over
        pollRunning = false
    }

    /// A session changed elsewhere (a voice turn was persisted). Refresh the list
    /// quietly, and silently re-hydrate the open thread if it's the one that changed.
    private func sessionChangedElsewhere(_ changedID: String?) async {
        await loadSessions(quiet: true)
        guard !streaming, let changedID, !changedID.isEmpty, changedID == sessionID else { return }
        await refreshActiveQuietly()
    }

    // MARK: Open / switch / new

    /// Open the most recent session, or stage a fresh one if there are none.
    func openInitial() async {
        guard !hasSession else { return }
        await loadSessions()
        if let first = sessions.first { await openSession(first.id) } else { startNewSession() }
    }

    func openSession(_ id: String) async {
        if streaming { await cancel() }
        sessionID = id
        error = nil
        setMessages([])
        pendingClarify = nil
        historyLoading = true
        inputTokens = nil
        outputTokens = nil
        estimatedCost = nil
        sessionTitle = sessions.first { $0.id == id }?.displayTitle ?? "Chat"
        do {
            let detail = try await sessionsAPI.get(id)
            if sessionID == id {
                if !detail.title.isEmpty { sessionTitle = detail.title }
                setMessages(detail.messages)
            }
        } catch {
            if sessionID == id { self.error = "Could not open chat: \(apiErrorMessage(error))" }
        }
        if sessionID == id { historyLoading = false }
    }

    /// Stage a brand-new conversation. The actual `POST /api/session/new` is
    /// deferred until the first message, matching the web UI's "an empty session
    /// writes nothing to disk" behaviour.
    func startNewSession() {
        cancelLocally()
        sessionID = nil
        sessionTitle = "New chat"
        setMessages([])
        error = nil
        pendingClarify = nil
        inputTokens = nil
        outputTokens = nil
        estimatedCost = nil
    }

    private func ensureSession() async throws -> String {
        if let id = sessionID, !id.isEmpty { return id }
        let id = try await sessionsAPI.create()
        sessionID = id
        return id
    }

    // MARK: Sending

    /// Send a turn and stream the reply. Returns when the turn has settled, so a
    /// caller that wants fire-and-forget wraps it in its own `Task`.
    func send(_ text: String, forceServer: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A typed reply while a clarify is open answers it — the turn is still
        // blocked, so don't start a new one. Pending attachments stay queued for
        // the next real send.
        if pendingClarify != nil {
            await respondClarify(trimmed)
            return
        }
        let attachments = pendingAttachments
        guard !(trimmed.isEmpty && attachments.isEmpty), !streaming else { return }

        error = nil
        attachError = nil
        pendingAttachments = []

        appendMessage(.user(trimmed, attachments: attachments.map(\.messageAttachment)))
        let live = ChatMessage.assistant(streaming: true)
        appendMessage(live)
        liveMessageID = live.id
        liveStreamID = nil
        lastPublishedClarify = nil
        turnStartedAt = clock.now
        streaming = true

        let state = ChatStreamState(message: live, startedAt: turnStartedAt)
        let task = Task { [weak self] in
            guard let self else { return }
            await runTurn(text: trimmed, attachments: attachments, forceServer: forceServer, initial: state)
        }
        turnHandle.replace(task)
        await task.value
    }

    /// Re-ask the prompt that produced `reply` on the SERVER, bypassing the
    /// on-device layer. Appends a fresh server turn — the local reply stays above
    /// so you can compare. A no-op while a turn is already streaming.
    func retryOnServer(_ reply: ChatMessage) async {
        guard !streaming,
              let index = messages.firstIndex(where: { $0.id == reply.id }), index > 0,
              let prompt = messages[..<index].last(where: { $0.isUser })?.plainText,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await send(prompt, forceServer: true)
    }

    /// Answer the agent's open clarify question so the blocked turn resumes.
    func respondClarify(_ answer: String) async {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let id = sessionID, !id.isEmpty else { pendingClarify = nil; return }
        let asked = pendingClarify
        pendingClarify = nil
        do {
            try await chatAPI.respondClarify(sessionID: id, answer: trimmed)
        } catch let failure {
            // The turn is still blocked on the server, so put the question back
            // rather than leaving the user staring at a dead "thinking"
            // (swift-correctness H12 / silent-failures H6).
            pendingClarify = asked
            lastPublishedClarify = asked
            error = "Couldn't send your answer: \(apiErrorMessage(failure))"
        }
    }

    private func runTurn(text: String, attachments: [ChatPendingAttachment],
                         forceServer: Bool, initial: ChatStreamState) async {
        var state = initial
        do {
            // On-device first: if the local layer fully handles the turn we never
            // hit the server. Attachments always go to the server — the local layer
            // can't take them — and `forceServer` is the "Try on server" retry.
            if !forceServer, attachments.isEmpty, let onDevice,
               await runOnDevice(onDevice, text: text, state: &state) {
                await loadSessions(quiet: true)
                return
            }
            let id = try await ensureSession()
            let (uploads, failed) = await uploadChatAttachments(attachments) { name, data in
                try await chatAPI.uploadFile(sessionID: id, data: data, filename: name)
            }
            attachError = chatAttachmentFailureMessage(failed)
            try await streamTurn(sessionID: id, text: text, uploads: uploads, state: &state)
        } catch is CancellationError {
            // Stop already settled the turn locally.
        } catch {
            failTurn(&state, apiErrorMessage(error))
        }
        // The turn changed this session's row (title, ordering). Quietly: a failed
        // background refresh must never stomp the view.
        await loadSessions(quiet: true)
    }

    private func streamTurn(sessionID id: String, text: String,
                            uploads: [[String: Any]], state: inout ChatStreamState) async throws {
        var events = chatAPI.sendMessage(
            sessionID: id, text: text,
            model: selectedModelID, provider: selectedProviderID,
            attachments: uploads.isEmpty ? nil : uploads)
        var reattaches = 0

        while true {
            do {
                let guarded = withStallDetection(events, limit: resilience.idleLimit,
                                                 step: resilience.checkStep, clock: clock)
                for try await event in guarded {
                    let changed = ChatStreamReducer.apply(event, to: &state, now: clock.now)
                    if let streamID = state.streamID { liveStreamID = streamID }
                    if changed { publish(state) }
                    if state.outcome != nil { break }
                }
                break
            } catch let error as APIError where Self.isBusy(error) && !state.receivedAnyEvent {
                // A turn is already running on this session — quite possibly our
                // own, if the phone's stream broke. Ride along with it.
                let snapshot = try await sessionsAPI.snapshot(id)
                guard let running = snapshot.activeStreamID else { throw error }
                liveStreamID = running
                events = chatAPI.streamEvents(running)
            } catch ChatStreamError.stalled {
                reattaches += 1
                guard reattaches <= resilience.maxReattach else { throw ChatStreamError.stalled }
                let snapshot = try? await sessionsAPI.snapshot(id)
                if let running = snapshot?.activeStreamID {
                    liveStreamID = running
                    events = chatAPI.streamEvents(running)
                    continue
                }
                // The turn finished while we weren't listening: take its text.
                if let snapshot, ChatStreamReducer.adopt(snapshot, into: &state) { publish(state) }
                break
            }
        }

        // A Stop or a session switch already settled this turn — a cancelled stream
        // ends cleanly rather than throwing, so bail out explicitly instead of
        // chasing a reply there is nowhere left to put.
        guard liveMessageID != nil, !Task.isCancelled else { return }

        // A turn that said nothing and did nothing: the server's record is
        // authoritative, so recover the reply from history rather than showing an
        // empty bubble.
        if !state.producedOutput, state.outcome != .cancelled,
           let snapshot = try? await sessionsAPI.snapshot(id),
           ChatStreamReducer.adopt(snapshot, into: &state) {
            publish(state)
        }
        finishTurn(&state)
    }

    private func runOnDevice(_ handler: OnDeviceChatHandler, text: String,
                             state: inout ChatStreamState) async -> Bool {
        // `emit` can't capture an `inout`, so the turn's state lives in a box while
        // the local model streams into it.
        let box = StateBox(state)
        let reply = await handler.answer(text) { [weak self] token in
            box.state.message.appendToken(token)
            self?.publish(box.state)
        }
        state = box.state
        guard case .answered(let input, let output) = reply else { return false }

        if state.message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.message.appendToken("At your service.")
        }
        state.message.onDevice = true
        var stats = state.message.stats ?? ChatTurnStats()
        stats.inputTokens = input
        stats.outputTokens = output
        state.message.stats = stats
        let answer = state.message.plainText
        finishTurn(&state)

        // Persist the local turn into the server session so it shows on the web and
        // other devices. Best-effort.
        if let id = try? await ensureSession() {
            await sessionsAPI.appendLocalTurn(id, user: text, assistant: Self.stripPersistedImages(answer))
        }
        return true
    }

    // MARK: Stop

    /// Stop the turn and tell the server to stop the agent too.
    func cancel() async {
        let streamID = liveStreamID
        cancelLocally()
        guard let streamID else { return }
        // The stream is already torn down locally; this just stops the agent.
        do { _ = try await chatAPI.cancel(streamID) } catch let failure {
            // The bubble already says the turn stopped; only the *server* side is
            // in doubt, so say so rather than implying it is definitely stopped
            // (silent-failures M10).
            JcLog.dropped(JcLog.chat, "cancel turn", failure)
            error = "Stopped locally — the server may still be running this turn."
        }
    }

    /// Settle the turn in the UI without telling the server — for a screen going
    /// away, or a new conversation replacing this one.
    func cancelLocally() {
        defer { turnHandle.cancel() }
        guard streaming else { return }
        streaming = false
        guard let id = liveMessageID, let index = messages.firstIndex(where: { $0.id == id }) else {
            liveMessageID = nil
            liveStreamID = nil
            return
        }
        var state = ChatStreamState(message: messages[index], startedAt: turnStartedAt)
        ChatStreamReducer.finish(&state, cancelled: true, now: clock.now)
        replaceMessage(at: index, with: state.message)
        liveMessageID = nil
        liveStreamID = nil
    }

    // MARK: Session mutations

    func renameSession(_ id: String, title: String) async {
        do { try await sessionsAPI.rename(id, title: title) } catch let failure {
            error = apiErrorMessage(failure)
            return
        }
        if id == sessionID { sessionTitle = title }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = title }
    }

    func pinSession(_ id: String, pinned: Bool) async {
        do { try await sessionsAPI.pin(id, pinned: pinned) } catch let failure {
            error = apiErrorMessage(failure)
            return
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].pinned = pinned }
    }

    func deleteSession(_ id: String) async {
        do { try await sessionsAPI.delete(id) } catch let failure {
            error = apiErrorMessage(failure)
            return
        }
        sessions.removeAll { $0.id == id }
        guard id == sessionID else { return }
        if let next = sessions.first { await openSession(next.id) } else { startNewSession() }
    }

    // MARK: Composer

    func addAttachment(_ attachment: ChatPendingAttachment) {
        attachError = nil
        pendingAttachments.append(attachment)
    }

    func removeAttachment(_ attachment: ChatPendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Per-message copy (the little button under a reply).
    func copy(_ message: ChatMessage) {
        clipboard.copy(message.plainText)
    }

    // MARK: Models

    func loadModels() async {
        do { models = try await modelsAPI.list() } catch {
            // Keep whatever catalogue we already have — a blank picker is worse
            // than a stale one — and only speak up when there is none
            // (silent-failures M11).
            let line = JcLog.report(JcLog.chat, "load models", error)
            if models == nil { self.error = "Could not load models: \(line)" }
        }
    }

    /// Pick a model for the chat surface; nil means "the server's default".
    ///
    /// The CANONICAL `providerID` is what travels as `model_provider`, not the
    /// display `provider` the picker groups under — the server routes on the id,
    /// and "Anthropic" instead of "anthropic" silently ran the turn on its own
    /// default model.
    func selectModel(_ model: ChatModel?) {
        selectedModelID = model?.id
        selectedProviderID = model?.providerID
        selection.set(.chat, model: model?.id, provider: model?.providerID)
    }

    // MARK: Transcript mutation

    /// Replace the whole transcript. The only public way in — see ``messages``.
    func setMessages(_ new: [ChatMessage]) {
        messages = new
        rows = ChatRow.rows(for: new)
        messagesTick &+= 1
    }

    private func appendMessage(_ message: ChatMessage) {
        let continues = messages.last?.role == message.role
        messages.append(message)
        rows.append(ChatRow(message: message, continuesSpeaker: continues))
        messagesTick &+= 1
    }

    /// Swap one message in place. Speaker grouping depends only on the roles of
    /// the neighbours, which an in-place replacement never changes, so the row
    /// keeps its flag — and a streamed token stays O(1) instead of rebuilding
    /// every row on the thread.
    private func replaceMessage(at index: Int, with message: ChatMessage) {
        messages[index] = message
        if rows.indices.contains(index), rows[index].message.role == message.role {
            rows[index].message = message
        } else {
            rows = ChatRow.rows(for: messages)
        }
        messagesTick &+= 1
    }

    // MARK: Publishing

    /// Copy the live turn's state into the transcript, if it's still there. A Stop
    /// or a session switch clears ``liveMessageID``, and everything an abandoned
    /// stream does afterwards is dropped.
    private func publish(_ state: ChatStreamState) {
        guard let id = liveMessageID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        replaceMessage(at: index, with: state.message)
        if let value = state.inputTokens { inputTokens = value }
        if let value = state.outputTokens { outputTokens = value }
        if let value = state.estimatedCost { estimatedCost = value }
        if let title = state.sessionTitle, !title.isEmpty { sessionTitle = title }
        // Only on a change, so answering a clarify can't be undone by a later frame.
        if state.clarify != lastPublishedClarify {
            lastPublishedClarify = state.clarify
            pendingClarify = state.clarify
        }
    }

    private func finishTurn(_ state: inout ChatStreamState, cancelled: Bool = false) {
        guard liveMessageID != nil else { return }
        ChatStreamReducer.finish(&state, cancelled: cancelled, now: clock.now)
        publish(state)
        streaming = false
        liveMessageID = nil
        liveStreamID = nil
    }

    private func failTurn(_ state: inout ChatStreamState, _ message: String) {
        guard liveMessageID != nil else {
            // Nothing live to blame — surface it at the screen level.
            error = message
            streaming = false
            return
        }
        ChatStreamReducer.fail(&state, message)
        publish(state)
        streaming = false
        liveMessageID = nil
        liveStreamID = nil
    }

    private static func isBusy(_ error: APIError) -> Bool {
        if case .http(let status, _) = error { return status == 409 }
        return false
    }

    /// Replace inline base64 data-URL images (`![alt](data:image/…;base64,…)`)
    /// with a short placeholder before persisting an on-device turn, so megabytes
    /// of base64 never reach the server session. The in-memory message the user
    /// sees keeps the full image — only the SERVER copy is trimmed.
    static func stripPersistedImages(_ text: String) -> String {
        text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\(data:image/[^)]+\\)",
                                  with: "[generated image]",
                                  options: .regularExpression)
    }
}

// MARK: - Helpers

/// A reference cell for turn state that a non-escaping token callback mutates.
private final class StateBox {
    var state: ChatStreamState
    init(_ state: ChatStreamState) { self.state = state }
}
