import Foundation
import Observation

/// One open coding session: its chat transcript, the interactive prompt, the
/// composer, and the live terminal.
///
/// Port of `_CodingChatViewState` + the terminal half of
/// `coding/coding_controller.dart`. The merge/expiry/classification rules live in
/// `CodingStreamReducer`; this is the shell that owns the clock, the tasks and
/// the buffer.
///
/// IMPORTANT (unchanged from Flutter): the terminal PTY **is** the input channel.
/// Free text = the bytes then `\r`, an option key = just the key, Esc = `\x1b`.
/// The transcript itself is polled from `/messages`, incrementally via `after`.
@Observable @MainActor
final class CodingSessionStore {

    // MARK: - Dependencies

    let sessionId: String
    private let api: CodingSessionsAPI
    let attachments: CodingAttachments
    private let isVisible: () -> Bool
    private let now: () -> Date

    init(sessionId: String,
         api: CodingSessionsAPI = CodingSessionsAPI(),
         attachments: CodingAttachments? = nil,
         isVisible: @escaping () -> Bool = { true },
         now: @escaping () -> Date = Date.init) {
        self.sessionId = sessionId
        self.api = api
        self.attachments = attachments ?? CodingAttachments(api: api)
        self.isVisible = isVisible
        self.now = now
    }

    deinit {
        pollHandle.cancel()
        echoHandle.cancel()
        bootstrapHandle.cancel()
        attachHandle.cancel()
        terminalHandle.cancel()
        reattachHandle.cancel()
    }

    // Every long-lived task lives in a `TaskHandle` (`Copilot/More/MoreSupport.swift`)
    // rather than a `nonisolated(unsafe) var`: the box is `Sendable`, so the
    // nonisolated `deinit` can cancel from anywhere while the task itself is
    // installed on the MainActor. Replacing a handle cancels what it displaced.
    @ObservationIgnored private let pollHandle = TaskHandle()
    @ObservationIgnored private let echoHandle = TaskHandle()
    @ObservationIgnored private let bootstrapHandle = TaskHandle()
    @ObservationIgnored private let attachHandle = TaskHandle()
    @ObservationIgnored private let terminalHandle = TaskHandle()
    @ObservationIgnored private let reattachHandle = TaskHandle()

    // MARK: - Transcript

    var transcript = CodingTranscript()

    /// Messages the user sent that haven't appeared in the transcript yet —
    /// rendered as "queued" bubbles so steering while Claude works has immediate
    /// visible feedback.
    var pendingSends: [PendingSend] = []

    /// Bumped whenever content was appended; the view watches it to auto-scroll.
    private(set) var appendTick = 0
    /// True when the last append should be a hard JUMP to the bottom (opening a
    /// chat / a full reload) rather than an animated scroll.
    private(set) var appendWasReload = false

    /// Optimistic "Claude is working" right after WE send something: the server's
    /// pane scan takes ~5s to flip the stored state, and without this the thinking
    /// bubble shows nothing exactly when feedback matters most.
    private var localWorkingUntil: Date?

    private var fetchTick = 0
    private var fetching = false

    var showThinking: Bool {
        CodingStreamReducer.showThinking(activityState: transcript.activityState,
                                         messageCount: transcript.messages.count,
                                         localWorkingUntil: localWorkingUntil,
                                         now: now())
    }

    func kickLocalWorking() {
        localWorkingUntil = now().addingTimeInterval(CodingStreamReducer.localWorkingWindow)
    }

    /// Fetch the transcript tail (or everything, with `full`). At most one
    /// self-heal reload per call: the reducer asks for it when the server rewound
    /// or skipped an index.
    func fetch(full requestedFull: Bool = false) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }

        var full = requestedFull
        if !full {
            fetchTick += 1
            if CodingStreamReducer.shouldFullReconcile(tick: fetchTick) { full = true }
        }

        for _ in 0..<2 {
            do {
                let after = CodingStreamReducer.cursor(transcript, full: full)
                let page = try await api.chatMessages(sessionId, after: after)
                switch CodingStreamReducer.apply(page, full: full, to: &transcript) {
                case .needsFullReload:
                    full = true
                    continue
                case .applied(let hadNew, let hadNewAssistant):
                    pendingSends = CodingStreamReducer.expirePendingSends(
                        pendingSends, page: page, messages: transcript.messages, now: now())
                    if CodingStreamReducer.retireLocalWorking(activityState: page.activityState,
                                                              hadNewAssistant: hadNewAssistant) {
                        localWorkingUntil = nil
                    }
                    if hadNew {
                        appendWasReload = full
                        appendTick += 1
                    }
                    await onActivityChanged()
                    return
                }
            } catch {
                // 409 = no transcript yet; anything else keeps the old list and
                // retries next tick.
                CodingStreamReducer.applyFetchFailure(error, to: &transcript)
                return
            }
        }
    }

    // MARK: - Poll loop

    /// True between `start()` and `stop()`. The bootstrap's `fetch(full:)` awaits
    /// the network, and the view can disappear while it does — without this flag
    /// it re-armed the poll loop *after* `stop()` and the session kept polling
    /// forever.
    private var started = false

    /// The live transcript-poll task, or nil when disarmed. Internal so the tests
    /// can prove `stop()` really disarms it.
    var pollTask: Task<Void, Never>? { pollHandle.current }

    /// First paint: attach the PTY (it's the input channel), load the transcript,
    /// and arm the self-rescheduling poll. Idempotent while started.
    func start() {
        guard !started else { return }
        started = true
        attachHandle.replace(Task { [weak self] in await self?.startTerminal() })
        bootstrapHandle.replace(Task { [weak self] in
            await self?.fetch(full: true)
            guard let self, !Task.isCancelled, self.started else { return }
            self.schedulePoll()
        })
    }

    func stop() {
        started = false
        bootstrapHandle.cancel()
        pollHandle.cancel()
        echoHandle.cancel()
    }

    /// Catch up and re-arm after the app comes back to the foreground.
    func resume() async {
        await fetch()
        // Backgrounding doesn't `stop()` us, but a resume that races a teardown
        // must not resurrect the loop.
        guard started else { return }
        schedulePoll()
    }

    /// Self-rescheduling so the interval tracks the live state — 2.5s while
    /// Claude is working/waiting (realtime), 4s when idle (battery).
    private func schedulePoll() {
        pollHandle.replace(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = CodingStreamReducer.pollInterval(
                    activityState: self.transcript.activityState, showThinking: self.showThinking)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self.pollTick()
            }
        })
    }

    /// One transcript-poll tick. Returns false — and does NO network work — while
    /// the tab/session is hidden or the app is backgrounded.
    @discardableResult
    func pollTick() async -> Bool {
        guard isVisible() else { return false }
        await fetch()
        return true
    }

    // MARK: - Interactive prompt (activity_state == waiting)

    var prompt: CodingPromptState?
    /// The prompt the user closed — its sheet must not re-pop on the next tick.
    var dismissedPromptSignature: String?
    /// Set when a NEW prompt should be presented; the view clears it once shown.
    var shouldPresentPrompt = false
    /// True while the sheet is up, so the poll doesn't fight it.
    var promptOpen = false

    private var promptFetching = false

    private func onActivityChanged() async {
        if transcript.isWaiting {
            await checkPrompt()
        } else if prompt != nil || dismissedPromptSignature != nil {
            // The prompt resolved — forget it so the NEXT one pops fresh.
            prompt = nil
            dismissedPromptSignature = nil
            shouldPresentPrompt = false
        }
    }

    func checkPrompt() async {
        guard !promptFetching, !promptOpen else { return }
        promptFetching = true
        defer { promptFetching = false }
        // Best-effort; the header banner still lets the user open it manually.
        guard let p = await fetchPrompt(), p.waiting else { return }
        prompt = p
        if p.signature != dismissedPromptSignature { shouldPresentPrompt = true }
    }

    /// The prompt endpoint is best-effort on both paths — a failure just means
    /// the sheet doesn't pop this tick — but it is not worth losing silently.
    private func fetchPrompt() async -> CodingPromptState? {
        do { return try await api.chatPrompt(sessionId) } catch {
            JcLog.dropped(JcLog.coding, "chat prompt", error)
            return nil
        }
    }

    /// Open whatever Claude is asking, refetching if we don't hold it yet (the
    /// tappable "Needs input" banner).
    func promptForBanner() async -> CodingPromptState? {
        if let p = prompt, p.waiting { return p }
        guard let p = await fetchPrompt(), p.waiting else { return nil }
        prompt = p
        return p
    }

    /// Remember this prompt whether it was ANSWERED or dismissed: the activity
    /// scan takes a few seconds to flip out of "waiting", and re-popping the sheet
    /// the user just acted on is the glitch this guards against.
    func promptSheetClosed(_ p: CodingPromptState) async {
        promptOpen = false
        dismissedPromptSignature = p.signature
        shouldPresentPrompt = false
        // Answering usually flips the state quickly — refresh soon either way.
        await fetch()
    }

    // MARK: - Input (all of it through the terminal PTY)

    /// Raw byte sequence straight to the PTY (option keys, Esc, Enter). Returns
    /// whether it actually reached the server.
    @discardableResult
    func sendRaw(_ sequence: String) async -> Bool {
        let ok = await sendTerminalInput(sequence)
        if ok { kickLocalWorking() } // answering a prompt puts Claude back to work
        return ok
    }

    /// Free-text message: the text bytes, then Enter (`\r`) a beat later so the
    /// TUI registers it as typed input + submit.
    @discardableResult
    func sendText(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        guard await sendTerminalInput(text) else { return false }
        try? await Task.sleep(nanoseconds: 120_000_000)
        // Cancelled between the bytes and Enter: the TUI is holding un-submitted
        // text. Swallowing that used to report a send that never happened.
        guard !Task.isCancelled else {
            JcLog.coding.warning("sendText cancelled before the submit \\r")
            return false
        }
        _ = await sendTerminalInput("\r")
        pendingSends.append(PendingSend(text: text, ts: now()))
        appendWasReload = false
        appendTick += 1
        kickLocalWorking()
        // Pick the echo up quickly instead of waiting for the next tick.
        echoHandle.replace(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await self?.fetch()
        })
        return true
    }

    /// The composer's send: upload any attachments, fold their `@path` refs in,
    /// then type it. `failed` is how many attachments didn't upload — don't let a
    /// failed upload vanish silently, the message would otherwise go WITHOUT it.
    func sendComposer(_ raw: String) async -> (sent: Bool, failed: Int) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty { return (false, 0) }
        let r = await attachments.consume(into: text, sessionId: sessionId)
        guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, r.failed)
        }
        return (await sendText(r.text), r.failed)
    }

    /// The slash commands the Flutter command sheet offered.
    static let commands: [(command: String, help: String)] = [
        ("/compact", "Summarize the conversation and shrink context"),
        ("/clear", "Reset the conversation"),
        ("/context", "Show what is using up the context window"),
        ("/cost", "Show token usage and cost for this session"),
        ("/model", "Show or change the model"),
        ("/todos", "Show the current task list"),
    ]

    // MARK: - Live terminal

    /// The rendered PTY output. Replaces Flutter's xterm `Terminal`.
    var terminal = TerminalBuffer()
    /// Bumped on every write so the view can scroll the terminal to the bottom.
    private(set) var outputTick = 0
    var terminalError: String?
    var terminalStarting = false

    /// Whether our PTY attach is believed live (Flutter's `_terminalId == id`).
    private(set) var terminalAttached = false

    /// Bounded auto-retry budget after a soft 'reconnecting' close.
    private var reconnectAttempts = 0

    /// Attach a server-side PTY to this session's tmux and stream its output.
    /// Idempotent while attached.
    func startTerminal(rows: Int = 24, cols: Int = 80) async {
        guard !terminalAttached else { return }
        terminalAttached = true
        terminalStarting = true
        terminalError = nil
        defer { terminalStarting = false }
        do {
            try await api.terminalStart(sessionId, rows: rows, cols: cols)
            terminal.resize(rows: rows, cols: cols)
            terminalHandle.replace(Task { [weak self] in await self?.pumpTerminal() })
        } catch {
            // A discovered Mac session whose device is OFFLINE can't be attached
            // live — `CodingTerminalError.deviceOffline` points at resume-to-server.
            terminalError = (error as? CodingTerminalError)?.errorDescription
                ?? JcLog.report(JcLog.coding, "terminal attach", error)
            terminalAttached = false
        }
    }

    private func pumpTerminal() async {
        do {
            for try await frame in api.terminalOutput(sessionId) {
                switch CodingTerminalEvent(frame) {
                case .output(let text):
                    if !text.isEmpty {
                        terminal.write(text)
                        outputTick += 1
                    }
                    reconnectAttempts = 0 // healthy stream — reset the retry budget
                case .closed(let reason):
                    terminal.write(CodingTerminalEvent.notice(closedBecause: reason))
                    outputTick += 1
                    // Reset the attach guard so re-tapping the session re-attaches
                    // (the old bug: the guard stayed set, so reopen was a no-op
                    // forever).
                    terminalAttached = false
                    terminalStarting = false
                    // A brief Mac blip heals itself; the other reasons need the user.
                    if CodingTerminalEvent.shouldReattach(afterCloseReason: reason) {
                        scheduleReattach()
                    }
                    return
                case .failed(let message):
                    if !message.isEmpty {
                        terminal.write(CodingTerminalEvent.notice(error: message))
                        outputTick += 1
                    }
                case .other:
                    break
                }
            }
        } catch {
            // A dropped stream is NOT harmless: the empty catch left
            // `terminalAttached == true`, so every later `sendTerminalInput`
            // reported success into a PTY nobody was reading — the keystroke
            // vanished and the terminal stayed frozen until an app restart.
            // Mirror the `.closed` path instead: say so, clear the attach guard,
            // and retry on the same bounded budget.
            guard !Task.isCancelled else { return }
            let message = JcLog.report(JcLog.coding, "terminal stream", error)
            terminal.write(CodingTerminalEvent.notice(error: message))
            outputTick += 1
            terminalError = message
            terminalAttached = false
            terminalStarting = false
            scheduleReattach()
        }
    }

    private func scheduleReattach() {
        reconnectAttempts += 1
        guard let delay = CodingTerminalEvent.reattachDelay(attempt: reconnectAttempts) else {
            reconnectAttempts = 0
            return
        }
        reattachHandle.replace(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.terminalAttached else { return }
            await self.startTerminal()
        })
    }

    /// Send keystrokes from the terminal view / chat prompt to the PTY.
    ///
    /// Returns whether the bytes actually reached the server. If the attach has
    /// dropped (another device took over the single-viewer terminal, or the stream
    /// closed) it RE-ATTACHES first instead of silently no-oping — the old
    /// behaviour made chat-mode prompt answers vanish into the void.
    @discardableResult
    func sendTerminalInput(_ data: String) async -> Bool {
        guard !data.isEmpty else { return false }
        if !terminalAttached { await startTerminal() }
        guard terminalAttached else { return false }
        do {
            try await api.terminalInput(sessionId, data: data)
            terminalError = nil
            return true
        } catch {
            // The composer's warning only covers ITS send; a key-bar tap or a
            // prompt answer had nowhere to surface. The panel shows this above
            // the output rather than instead of it.
            terminalError = "Keystrokes aren’t reaching the session: "
                + JcLog.report(JcLog.coding, "terminal input", error)
            return false
        }
    }

    /// Push the view's dimensions to the PTY (and to the local buffer).
    func resizeTerminal(rows: Int, cols: Int) {
        terminal.resize(rows: rows, cols: cols)
        guard terminalAttached else { return }
        let api = self.api
        let id = sessionId
        // Fire-and-forget, but not silent: a rejected resize means tmux and the
        // pane disagree about the width and the repaint looks shredded.
        Task { [weak self] in
            do { try await api.terminalResize(id, rows: rows, cols: cols) }
            catch { self?.noteTerminalResizeFailure(error) }
        }
    }

    private func noteTerminalResizeFailure(_ error: Error) {
        JcLog.dropped(JcLog.coding, "terminal resize", error)
    }

    /// Detach the live terminal (server PTY + SSE) WITHOUT refreshing — used when
    /// a session ends while viewed, or when the selection moves on, so the dead
    /// tmux's stream/PTY isn't left dangling. Idempotent.
    func detachTerminal() {
        terminalHandle.cancel()
        reattachHandle.cancel()
        if terminalAttached {
            let api = self.api
            let id = sessionId
            // Detaching does NOT kill the tmux session / claude — but a close
            // that never lands leaks the server-side PTY, and the single-viewer
            // terminal then answers the NEXT attach with a 409. Worth one retry.
            Task { [weak self] in
                do { try await api.terminalClose(id) } catch {
                    JcLog.dropped(JcLog.coding, "terminal close", error)
                    try? await Task.sleep(nanoseconds: Self.closeRetryDelay)
                    do { try await api.terminalClose(id) }
                    catch { self?.noteTerminalCloseFailure(error) }
                }
            }
        }
        terminalAttached = false
        terminalStarting = false
    }

    /// Short enough that a detach-then-reopen still finds the PTY released.
    static let closeRetryDelay: UInt64 = 400_000_000

    private func noteTerminalCloseFailure(_ error: Error) {
        terminalError = "Couldn’t release the terminal: "
            + JcLog.report(JcLog.coding, "terminal close (retry)", error)
            + " — reopening may need a moment."
    }
}
