import Foundation

/// The on-device lane for a SPOKEN turn: decide whether this phone can finish the
/// turn itself, so `end_turn` never goes to the server.
///
/// Port of `voice_controller._tryLocalTurn` / `_runLocalAction`. Two layers,
/// cheapest first:
///
///  1. ``LocalExecutor`` — a literal grammar over this phone's own skills. No
///     model, no network: "flashlight on" completes in tens of milliseconds.
///  2. ``LocalRouter`` — the on-device model answers conversation/knowledge; the
///     full reply is then streamed out of the engine (the router's inline answer
///     field is short and would truncate).
///
/// Deciding is separated from acting so the whole policy can be unit-tested with
/// no audio, no skills registry and no engine.
@MainActor
final class VoiceLocalLane {

    /// What the lane decided about one spoken turn.
    enum Plan {
        /// Run this device action, then acknowledge it out loud.
        case action(LocalRun)
        /// Speak this reply — it was generated on-device.
        case speak(String)
        /// Hand the turn to the server, with the reason (for logs).
        case escalate(String)

        var escalateReason: String? {
            if case .escalate(let reason) = self { return reason }
            return nil
        }
    }

    /// Streams a full on-device reply for one turn.
    typealias Answering = @MainActor (String) async -> String
    /// Routes one turn. Injectable because the escalation policy below has to
    /// hold for plans the production router does not (yet) emit — a
    /// confirm-required action, or one that only the InvokeRunner can dispatch.
    typealias Routing = @MainActor (String, VoiceSurface) async -> RouteResult

    private let settings: LocalAiSettings
    private let route: Routing
    private let executor: any VoiceLocalExecuting
    private let skills: @MainActor () -> Set<String>
    private let answer: Answering

    /// Every dependency is `nil`-defaulted and built in the body: default
    /// argument expressions are evaluated in a NONISOLATED context and most of
    /// these are `@MainActor`.
    init(settings: LocalAiSettings? = nil,
         router: LocalRouter? = nil,
         route: Routing? = nil,
         executor: (any VoiceLocalExecuting)? = nil,
         skills: (@MainActor () -> Set<String>)? = nil,
         answer: Answering? = nil) {
        self.settings = settings ?? .shared
        let router = router ?? LocalRouter()
        self.route = route ?? { text, surface in await router.handle(text, surface: surface) }
        self.executor = executor ?? DefaultVoiceLocalExecutor()
        self.skills = skills ?? { LocalExecutor.deviceSkills() }
        self.answer = answer ?? { text in
            await OnDeviceAI.shared.generateAll(text, surface: .voice)
        }
    }

    /// What to do with `transcript`. Never throws; the caller escalates on
    /// anything it doesn't recognise.
    func plan(_ transcript: String) async -> Plan {
        guard settings.enabledForVoice else { return .escalate("voice-disabled") }

        // Layer 1: the literal grammar. Checked even when the model is
        // unavailable — it needs neither.
        if settings.commandShortCircuit,
           case .run(let run) = LocalExecutor.classify(transcript, skills: skills()) {
            debugLogLocalDecision(.run(run))
            return .action(run)
        }

        // Layer 2: the on-device model.
        switch await route(transcript, .voice) {
        case .escalate(let reason):
            return .escalate(reason)

        case .toolCall(let plan):
            // Outward/destructive actions defer to the server's approval flow.
            if plan.requiresConfirm && settings.confirmLocalActions {
                return .escalate("requires-confirm")
            }
            guard plan.execClass == .deviceLocal else { return .escalate("not-device-local") }
            let ack = plan.confirmation.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Done — \(plan.name.replacingOccurrences(of: "_", with: " "))."
            return .action(LocalRun(skill: plan.name, args: plan.args, ack: ack))

        case .directAnswer(let inline):
            let generated = await answer(transcript)
            let spoken = generated.isEmpty
                ? inline.trimmingCharacters(in: .whitespacesAndNewlines)
                : generated
            // A local turn that produced no words is worse than no local turn —
            // let the server answer it rather than saying something empty.
            guard !spoken.isEmpty else { return .escalate("empty-local-answer") }
            return .speak(spoken)
        }
    }

    /// Run one classified device action.
    func run(_ plan: LocalRun) async -> LocalRunOutcome {
        await executor.execute(plan)
    }
}

/// Runs one classified device action. Behind a protocol so a voice test doesn't
/// have to stand up the whole skill registry.
@MainActor
protocol VoiceLocalExecuting {
    func execute(_ plan: LocalRun) async -> LocalRunOutcome
}

@MainActor
struct DefaultVoiceLocalExecutor: VoiceLocalExecuting {
    let runner: InvokeRunner

    init(runner: InvokeRunner? = nil) { self.runner = runner ?? .shared }

    func execute(_ plan: LocalRun) async -> LocalRunOutcome {
        await LocalExecutor(runner).execute(plan)
    }
}

// MARK: - Store wiring

extension VoiceStore {

    /// Try to finish this spoken turn on the device. Returns true when the turn is
    /// DONE locally — the caller then does NOT send `end_turn`.
    ///
    /// Bails whenever the turn was superseded (`epoch`), so a barge-in or a Stop
    /// can't be talked over by a late local answer.
    func tryLocalTurn(_ transcript: String, epoch: Int) async -> Bool {
        guard let local else { return false }
        let plan = await local.plan(transcript)
        guard epoch == turnEpoch, machine.state.isActive else { return false }

        switch plan {
        case .escalate(let reason):
            note("local lane escalated (\(reason))")
            return false

        case .action(let run):
            let outcome = await local.run(run)
            guard epoch == turnEpoch, machine.state.isActive else { return true }
            // An action that didn't take is NOT a local answer — escalate rather
            // than claiming something happened.
            guard outcome.ok else { return false }
            await acknowledgeLocally(outcome.spoken)
            // The server API has no "silent turn" flag, so the same append path
            // on-device replies use records the action WITHOUT running the agent.
            persistLocalTurn(user: transcript,
                             assistant: LocalExecutor.reportLine(run, outcome))
            lastLocalTranscript = transcript // enables "Try on server"
            return true

        case .speak(let text):
            await speakLocally(text)
            persistLocalTurn(user: transcript, assistant: text)
            lastLocalTranscript = transcript // enables "Try on server"
            return true
        }
    }

    /// Persist a completed on-device voice turn into the voice session so it shows
    /// on the web and other devices. Fire-and-forget: it must never delay the
    /// spoken reply, and a failure only costs a missing transcript line.
    func persistLocalTurn(user: String, assistant: String) {
        guard let sessionID, !sessionID.isEmpty else { return }
        let sessions = SessionsAPI(api: voice.api)
        Task {
            await sessions.appendLocalTurn(sessionID, user: user, assistant: assistant)
            // Tell the chat screen this session gained a turn so it shows up
            // without a manual reload.
            ChatSyncBus.shared.sessionChanged(sessionID)
        }
    }

    /// Clear the server's per-turn audio buffer after we answered a turn locally
    /// and skipped `end_turn`, so the NEXT turn starts clean. Without this the
    /// server keeps this turn's PCM and prepends it to the next one.
    func resetServerTurn() {
        guard let sessionID, !sessionID.isEmpty else { return }
        session.send(beginTurn(sessionID: sessionID))
        if !audio.isBusy { raise(.playbackDrained) }
    }
}
