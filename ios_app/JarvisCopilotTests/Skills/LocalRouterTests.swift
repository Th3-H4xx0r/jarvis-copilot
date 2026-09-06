import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/local_router_test.dart` and
/// `test/services/local_router_local_actions_test.dart`.
///
/// The Dart tests got an empty `SkillRegistry` for free (one isolate per test
/// file); here the available-skill set is injected explicitly, which is also how
/// the production router gets it.
@MainActor
final class LocalRouterTests: XCTestCase {

    private func settings(tier: LocalAiTier = .routerCommands,
                          chat: Bool = true,
                          voice: Bool = true) -> LocalAiSettings {
        let s = LocalAiSettings(store: MemoryKeyValueStore())
        s.tier = tier
        s.chatEnabled = chat
        s.voiceEnabled = voice
        return s
    }

    private func router(_ settings: LocalAiSettings,
                        model: any OnDeviceModel = MockOnDeviceModel(),
                        skills: Set<String> = []) -> LocalRouter {
        LocalRouter(model: model, settings: settings, availableSkills: { skills })
    }

    // MARK: gating

    func testTierOffEscalates() async {
        let r = router(settings(tier: .off))
        let res = await r.handle("hello", surface: .chat)
        XCTAssertEqual(res.escalateReason, "tier-off")
    }

    func testSurfaceDisabledEscalates() async {
        let r = router(settings(chat: false))
        let res = await r.handle("hello", surface: .chat)
        XCTAssertEqual(res.escalateReason, "chat-disabled")
    }

    func testEmptyInputEscalates() async {
        let r = router(settings())
        let res = await r.handle("   ", surface: .chat)
        XCTAssertEqual(res.escalateReason, "empty-input")
    }

    func testUnavailableEngineEscalates() async {
        let r = router(settings(),
                       model: MockOnDeviceModel(availabilityValue: .unavailable("off")))
        let res = await r.handle("hello", surface: .chat)
        let reason = res.escalateReason
        XCTAssertTrue(reason?.contains("unavailable") ?? false, reason ?? "nil")
    }

    // MARK: pre-gate (server requests escalate)

    func testServerRequestsEscalate() async {
        let r = router(settings())
        for cmd in [
            "what's the weather",
            "give me the morning brief",
            "play hello on Spotify",
            "what's on my calendar",
            "set an alarm for 10:30pm",
            "send an email to mom",
            "any news today",
            "open Spotify on my Mac",   // cross-device → server
        ] {
            let res = await r.handle(cmd, surface: .chat)
            XCTAssertEqual(res.escalateReason, "server-request", cmd)
        }
    }

    // MARK: instant local commands

    func testOpenSpotifyBecomesAnOpenAppToolCall() async throws {
        let r = router(settings())
        let res = await r.handle("open Spotify", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "open_app")
        XCTAssertEqual(plan.args["name"] as? String, "Spotify")
    }

    func testTurnOnTheFlashlightBecomesAToolCall() async throws {
        let r = router(settings())
        let res = await r.handle("turn on the flashlight", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "flashlight_on")
    }

    func testVibrateBecomesAToolCall() async throws {
        let r = router(settings())
        let res = await r.handle("vibrate", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "vibrate")
    }

    func testSetVolumeGoesThroughPhoneControl() async throws {
        let r = router(settings())
        let res = await r.handle("set volume to 30", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "phone_control")
        XCTAssertEqual(plan.args["action"] as? String, "volume")
        XCTAssertEqual(plan.args["value"] as? String, "30")
    }

    func testTextSomeoneGoesThroughTheSendMessageShortcut() async throws {
        let r = router(settings())
        let res = await r.handle("text Chahel hi", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "phone_control")
        XCTAssertEqual(plan.args["action"] as? String, "send_message")
        XCTAssertEqual(plan.args["to"] as? String, "Chahel")
        XCTAssertEqual(plan.args["message"] as? String, "hi")
    }

    // MARK: conversation stays local

    func testConversationStaysLocal() async {
        let r = router(settings())
        for msg in ["hello", "who are you", "what can you do", "tell me a poem",
                    "how are you", "good evening"] {
            let res = await r.handle(msg, surface: .chat)
            guard case .directAnswer = res else {
                return XCTFail("\"\(msg)\" should stay local, got \(res)")
            }
        }
    }

    // MARK: allow-listed device actions (local_router_local_actions_test.dart)

    func testAnAllowListedDeviceActionBecomesADeviceLocalToolCall() async throws {
        let r = router(settings(), skills: ["set_alarm", "clipboard_read", "vibrate"])
        let res = await r.handle("set a timer for 10 minutes", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "set_alarm")
        XCTAssertEqual(plan.args["in_minutes"] as? Int, 10)
        XCTAssertEqual(plan.execClass, .deviceLocal)
        XCTAssertFalse(plan.confirmation?.isEmpty ?? true)
    }

    func testASkillThisDeviceDoesNotHaveIsNeverRunLocally() async {
        let r = router(settings(), skills: ["set_alarm", "clipboard_read", "vibrate"])
        // take_photo is deliberately not in the set above.
        let res = await r.handle("take a photo", surface: .chat)
        XCTAssertNil(res.plan)
    }

    func testAGuardedUtteranceEscalatesInsteadOfRunning() async {
        let r = router(settings(), skills: ["set_alarm", "clipboard_read", "vibrate"])
        let res = await r.handle("set a timer for 10 minutes on my Mac", surface: .chat)
        XCTAssertNotNil(res.escalateReason)
    }

    func testTheOlderMatcherStillHandlesWhatTheExecutorSkips() async throws {
        let r = router(settings(), skills: ["set_alarm", "clipboard_read", "vibrate"])
        let res = await r.handle("vibrate the phone", surface: .chat)
        let plan = try XCTUnwrap(res.plan)
        XCTAssertEqual(plan.name, "vibrate")
    }

    // MARK: voice surface uses its own switch

    func testVoiceSurfaceHasItsOwnGate() async {
        let r = router(settings(chat: true, voice: false))
        let res = await r.handle("hello", surface: .voice)
        XCTAssertEqual(res.escalateReason, "voice-disabled")
    }

    // MARK: looksLikeServerRequest

    func testLooksLikeServerRequestMatchesCommandsAndLiveData() {
        for text in ["text mom", "play jazz", "what's the weather", "my calendar",
                     "set a timer", "find a restaurant"] {
            XCTAssertTrue(LocalRouter.looksLikeServerRequest(text), text)
        }
        for text in ["hello", "who are you", "tell me a poem", "good evening"] {
            XCTAssertFalse(LocalRouter.looksLikeServerRequest(text), text)
        }
    }
}
