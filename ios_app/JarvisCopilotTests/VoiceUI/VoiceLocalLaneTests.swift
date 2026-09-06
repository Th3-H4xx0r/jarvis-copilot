import XCTest
@testable import JarvisCopilot

/// The on-device lane for a SPOKEN turn. The contract that matters to the server:
/// when the phone answers the turn itself, `end_turn` must NOT go out — otherwise
/// the agent answers a second time over the top of the local reply.
@MainActor
final class VoiceLocalLaneTests: XCTestCase {

    // MARK: - The policy (VoiceLocalLane.plan)

    private func lane(settings: LocalAiSettings? = nil,
                      skills: Set<String> = [],
                      answer: String = "At your service.",
                      executor: (any VoiceLocalExecuting)? = nil,
                      engine: OnDeviceEngineAvailability = .available) -> VoiceLocalLane {
        let settings = settings ?? onDeviceSettings()
        let router = LocalRouter(
            model: AppleFoundationModel(engine: FakeOnDeviceEngine(availability: engine)),
            settings: settings,
            availableSkills: { skills })
        return VoiceLocalLane(settings: settings,
                              router: router,
                              executor: executor ?? StubVoiceLocalExecutor(),
                              skills: { skills },
                              answer: { _ in answer })
    }

    func testDisabledVoiceSurfaceEscalates() async {
        let plan = await lane(settings: onDeviceSettings(voice: false)).plan("hello")
        XCTAssertEqual(plan.escalateReason, "voice-disabled")
    }

    func testServerRequestsEscalate() async {
        let plan = await lane().plan("what's the weather in Paris")
        XCTAssertEqual(plan.escalateReason, "server-request")
    }

    func testUnavailableEngineEscalates() async {
        let plan = await lane(engine: .unavailable("modelNotReady")).plan("who are you")
        XCTAssertEqual(plan.escalateReason, "unavailable:modelNotReady")
    }

    /// The literal grammar runs first — no model, no network, tens of ms.
    func testDeviceCommandsBecomeAnAction() async {
        let plan = await lane(skills: ["flashlight_on"]).plan("turn on the flashlight")
        guard case .action(let run) = plan else { return XCTFail("expected .action, got \(plan)") }
        XCTAssertEqual(run.skill, "flashlight_on")
        XCTAssertEqual(run.ack, "Flashlight on, sir.")
    }

    func testConversationBecomesASpokenLocalAnswer() async {
        let plan = await lane(answer: "I'm JARVIS, sir.").plan("who are you")
        guard case .speak(let text) = plan else { return XCTFail("expected .speak, got \(plan)") }
        XCTAssertEqual(text, "I'm JARVIS, sir.")
    }

    /// A local turn that produced no words is worse than no local turn at all.
    func testEmptyLocalAnswerEscalates() async {
        let plan = await lane(answer: "").plan("who are you")
        XCTAssertEqual(plan.escalateReason, "empty-local-answer")
    }

    // MARK: - The escalation policy for a routed tool call

    /// A lane whose router hands back exactly `result` — the production router
    /// only ever emits device-local plans, so these branches need one.
    private func routedLane(_ result: RouteResult,
                            settings: LocalAiSettings? = nil) -> VoiceLocalLane {
        VoiceLocalLane(settings: settings ?? onDeviceSettings(),
                       route: { _, _ in result },
                       executor: StubVoiceLocalExecutor(),
                       skills: { [] },
                       answer: { _ in "" })
    }

    /// Outward/destructive actions defer to the server's approval flow.
    func testAConfirmRequiredActionEscalatesWhileConfirmationIsOn() async {
        let plan = ToolCallPlan(name: "send_sms", args: ["to": "mum"],
                                execClass: .deviceLocal, requiresConfirm: true,
                                confirmation: "Texting mum.")
        let result = await routedLane(.toolCall(plan)).plan("text mum I'm late")
        XCTAssertEqual(result.escalateReason, "requires-confirm")
    }

    /// With confirmation switched off the same plan runs on the phone.
    func testAConfirmRequiredActionFiresWhenConfirmationIsOff() async {
        let settings = onDeviceSettings()
        settings.confirmLocalActions = false
        let plan = ToolCallPlan(name: "send_sms", args: ["to": "mum"],
                                execClass: .deviceLocal, requiresConfirm: true,
                                confirmation: "Texting mum.")
        let result = await routedLane(.toolCall(plan), settings: settings)
            .plan("text mum I'm late")

        guard case .action(let run) = result else { return XCTFail("expected .action, got \(result)") }
        XCTAssertEqual(run.skill, "send_sms")
        XCTAssertEqual(run.ack, "Texting mum.")
    }

    /// The voice lane only runs things the PHONE can do offline; anything that
    /// needs the InvokeRunner (or the bridge) is the server's job.
    func testAClientDispatchablePlanIsNotDeviceLocal() async {
        let plan = ToolCallPlan(name: "play_audio", args: [:], execClass: .clientDispatchable)
        let result = await routedLane(.toolCall(plan)).plan("play something")
        XCTAssertEqual(result.escalateReason, "not-device-local")
    }

    func testAServerOnlyPlanIsNotDeviceLocalEither() async {
        let plan = ToolCallPlan(name: "search_web", args: [:], execClass: .serverOnly)
        let result = await routedLane(.toolCall(plan)).plan("look that up")
        XCTAssertEqual(result.escalateReason, "not-device-local")
    }

    /// A plan with no confirmation line still gets a spoken ack.
    func testAPlanWithoutAConfirmationGetsAGeneratedAck() async {
        let plan = ToolCallPlan(name: "flashlight_on", args: [:], execClass: .deviceLocal,
                                confirmation: "")
        let result = await routedLane(.toolCall(plan)).plan("light")
        guard case .action(let run) = result else { return XCTFail("expected .action, got \(result)") }
        XCTAssertEqual(run.ack, "Done — flashlight on.")
    }

    // MARK: - The grammar short-circuit

    /// Layer 1 needs neither model nor network, so a device command still works
    /// with the engine unavailable…
    func testTheGrammarShortCircuitAnswersWithNoEngine() async {
        let plan = await lane(skills: ["flashlight_on"],
                              engine: .unavailable("modelNotReady"))
            .plan("turn on the flashlight")
        guard case .action(let run) = plan else { return XCTFail("expected .action, got \(plan)") }
        XCTAssertEqual(run.skill, "flashlight_on")
    }

    /// …and turning the short-circuit off puts the router (and therefore engine
    /// availability) back in front of it.
    func testTurningTheShortCircuitOffSkipsTheGrammar() async {
        let settings = onDeviceSettings()
        settings.commandShortCircuit = false
        let plan = await lane(settings: settings, skills: ["flashlight_on"],
                              engine: .unavailable("modelNotReady"))
            .plan("turn on the flashlight")
        XCTAssertEqual(plan.escalateReason, "unavailable:modelNotReady")
    }

    // MARK: - The wiring (VoiceStore.tryLocalTurn + finishStreamedTurn)

    /// A device command answered on the phone: no `end_turn`, and the reply the
    /// user hears is the local ack.
    func testALocalActionSuppressesTheServerTurn() async {
        let harness = Harness(skills: ["flashlight_on"], transcript: "turn on the flashlight")
        await harness.runTurn()

        XCTAssertFalse(harness.socket?.sentTypes.contains("end_turn") ?? true,
                       "a locally-answered turn must not ask the server to answer it too")
        XCTAssertEqual(harness.store.userTranscript, "turn on the flashlight")
        XCTAssertEqual(harness.synthesizer.spoken, ["Flashlight on, sir."])
        XCTAssertTrue(harness.store.assistantText.contains("Flashlight on"))
        // The server's per-turn audio buffer is reset so the NEXT turn is clean.
        XCTAssertEqual(harness.socket?.sentTypes.filter { $0 == "begin_turn" }.count, 2)
    }

    func testALocalAnswerSuppressesTheServerTurn() async {
        let harness = Harness(transcript: "who are you", answer: "I'm JARVIS, sir.")
        await harness.runTurn()

        XCTAssertFalse(harness.socket?.sentTypes.contains("end_turn") ?? true)
        XCTAssertTrue(harness.store.assistantText.contains("JARVIS"))
    }

    /// Anything the phone can't finish goes to the server WITH the transcript, so
    /// the server skips its own STT.
    func testAnEscalatedTurnStillGoesToTheServer() async {
        let harness = Harness(transcript: "what's the weather in Paris")
        await harness.runTurn()

        let endTurn = harness.socket?.lastMessage(ofType: "end_turn")
        XCTAssertNotNil(endTurn, "an escalated turn must reach the server")
        XCTAssertEqual(endTurn?["text"] as? String, "what's the weather in Paris")
    }

    /// With no lane at all — every build until the tier is switched on — the turn
    /// goes to the server exactly as before.
    func testNoLaneMeansEveryTurnGoesToTheServer() async {
        let harness = Harness(transcript: "who are you", lane: false)
        await harness.runTurn()
        XCTAssertNotNil(harness.socket?.lastMessage(ofType: "end_turn"))
    }

    /// An action that didn't take must NOT be claimed — the server gets the turn.
    func testAFailedLocalActionFallsBackToTheServer() async {
        let harness = Harness(skills: ["flashlight_on"], transcript: "turn on the flashlight",
                              executionSucceeds: false)
        await harness.runTurn()
        XCTAssertNotNil(harness.socket?.lastMessage(ofType: "end_turn"))
        XCTAssertTrue(harness.synthesizer.spoken.isEmpty)
    }

    // MARK: - Harness

    /// Drives one realtime turn end to end with every platform boundary mocked.
    @MainActor
    final class Harness {
        let store: VoiceStore
        let input = MockAudioInput()
        let recognizer = MockSpeechRecognizing()
        let synthesizer = MockVoiceSynthesizing()
        let connector = MockVoiceSocketConnector()
        let clock = TestVoiceClock()
        private let transcript: String

        var socket: MockVoiceSocket? { connector.socket }

        init(skills: Set<String> = [],
             transcript: String,
             answer: String = "At your service.",
             lane: Bool = true,
             executionSucceeds: Bool = true) {
            self.transcript = transcript
            recognizer.nextTranscript = transcript

            let settings = onDeviceSettings()
            let router = LocalRouter(model: AppleFoundationModel(engine: FakeOnDeviceEngine()),
                                     settings: settings,
                                     availableSkills: { skills })
            let localLane = VoiceLocalLane(
                settings: settings,
                router: router,
                executor: StubVoiceLocalExecutor(succeeds: executionSucceeds),
                skills: { skills },
                answer: { _ in answer })

            let (api, transport) = JarvisAPI.mocked()
            // Routed (not FIFO) so background chatter can't eat a queued reply.
            transport.route("/api/voice/session", json: ["session_id": "voice-1"])
            transport.route("/api/devices", json: [])
            transport.route("/api/session", json: ["session": ["active_stream_id": ""]])
            store = VoiceStore(api: api,
                               input: input,
                               output: MockAudioOutput(),
                               recognizer: recognizer,
                               synthesizer: synthesizer,
                               audioSession: MockAudioSessionControlling(),
                               connector: connector,
                               clock: clock,
                               keyValueStore: MemoryKeyValueStore(),
                               launch: nil,
                               local: lane ? localLane : nil)
        }

        /// Start a realtime session, speak, then end the utterance.
        func runTurn() async {
            await store.primaryAction()
            await waitUntilVoice { self.store.state != .connecting }
            await settleVoiceTasks()
            input.emitFrames(amplitude: 0.5, ms: 200)
            store.finishSpeaking()
            await waitUntilVoice {
                (self.socket?.sentTypes.contains("end_turn") ?? false)
                    || !self.store.assistantText.isEmpty
                    || !self.synthesizer.spoken.isEmpty
            }
            await settleVoiceTasks()
        }
    }
}

/// A ``VoiceLocalExecuting`` that never touches the skill registry.
@MainActor
final class StubVoiceLocalExecutor: VoiceLocalExecuting {
    var succeeds: Bool
    private(set) var executed: [String] = []

    init(succeeds: Bool = true) { self.succeeds = succeeds }

    func execute(_ plan: LocalRun) async -> LocalRunOutcome {
        executed.append(plan.skill)
        return succeeds
            ? LocalRunOutcome(ok: true, spoken: plan.ack, detail: nil)
            : LocalRunOutcome(ok: false, spoken: LocalExecutor.failureAck, detail: "error:test")
    }
}
