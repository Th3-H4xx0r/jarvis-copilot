import XCTest
@testable import JarvisCopilot

/// The ``OnDeviceModel`` availability matrix and streaming contract, against a
/// fake engine — the part of the port that decides whether a turn stays on the
/// phone or goes to the server.
@MainActor
final class AppleFoundationModelTests: XCTestCase {

    // MARK: - Availability matrix

    func testAvailableEngineReportsAvailable() async {
        let model = AppleFoundationModel(engine: FakeOnDeviceEngine(availability: .available))
        let availability = await model.availability()
        XCTAssertTrue(availability.available)
        XCTAssertEqual(availability.engine, "apple-fm")
        XCTAssertNil(availability.reason)
    }

    /// Every reason Apple can give must survive verbatim — the settings screen
    /// shows it, and "deviceNotEligible" vs "appleIntelligenceNotEnabled" is the
    /// difference between "buy a new phone" and "flip a switch".
    func testUnavailableReasonsArePropagated() async {
        for reason in ["deviceNotEligible", "appleIntelligenceNotEnabled",
                       "modelNotReady", "ios-below-26", "foundationmodels-unavailable"] {
            let model = AppleFoundationModel(engine: FakeOnDeviceEngine(availability: .unavailable(reason)))
            let availability = await model.availability()
            XCTAssertFalse(availability.available, reason)
            XCTAssertEqual(availability.reason, reason)
            // Deviation from Dart (which collapsed to "none"): keep the engine id
            // so the UI can name which engine is unavailable.
            XCTAssertEqual(availability.engine, "apple-fm")
        }
    }

    func testMLXSlotIsPermanentlyUnavailable() async {
        let model = AppleFoundationModel(engine: MLXEngineSlot())
        let availability = await model.availability()
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.engine, "mlx")
        XCTAssertEqual(availability.reason, MLXEngineSlot.unavailableReason)
    }

    /// The whole point of the wiring: an unavailable engine makes the router
    /// escalate, which is byte-for-byte the behaviour before this port landed.
    func testRouterEscalatesWhenTheEngineIsUnavailable() async {
        let router = LocalRouter(model: AppleFoundationModel(
                                    engine: FakeOnDeviceEngine(availability: .unavailable("modelNotReady"))),
                                 settings: onDeviceSettings(),
                                 availableSkills: { [] })
        let result = await router.handle("hello there", surface: .chat)
        XCTAssertEqual(result.escalateReason, "unavailable:modelNotReady")
    }

    func testRouterAnswersLocallyWhenTheEngineIsAvailable() async {
        let router = LocalRouter(model: AppleFoundationModel(engine: FakeOnDeviceEngine()),
                                 settings: onDeviceSettings(),
                                 availableSkills: { [] })
        let result = await router.handle("who are you", surface: .chat)
        XCTAssertNil(result.escalateReason)
    }

    // MARK: - Generation

    func testGenerateStreamsEveryDelta() async throws {
        let engine = FakeOnDeviceEngine(chunks: ["At ", "your ", "service."])
        let model = AppleFoundationModel(engine: engine)
        var received: [String] = []
        for try await chunk in model.generate(request("hello")) { received.append(chunk) }
        XCTAssertEqual(received, ["At ", "your ", "service."])
    }

    func testGenerateSurfacesEngineFailures() async {
        let model = AppleFoundationModel(
            engine: FakeOnDeviceEngine(generateError: OnDeviceEngineError("ios-below-26")))
        do {
            for try await _ in model.generate(request("hello")) {}
            XCTFail("expected the engine error to surface")
        } catch {
            XCTAssertEqual(error as? OnDeviceEngineError, OnDeviceEngineError("ios-below-26"))
        }
    }

    /// The persona is what makes an on-device reply sound like the same JARVIS as
    /// a server one, so it has to reach the engine's system prompt.
    func testPersonaLeadsTheSystemPrompt() async throws {
        let engine = FakeOnDeviceEngine(chunks: ["ok"])
        let model = AppleFoundationModel(engine: engine, persona: OnDevicePersona("You are JARVIS."))
        for try await _ in model.generate(request("hi")) {}
        let sent = await engine.lastRequest
        XCTAssertEqual(sent?.prompt, "hi")
        XCTAssertTrue(sent?.system.hasPrefix("You are JARVIS.") ?? false, sent?.system ?? "nil")
        XCTAssertTrue(sent?.system.contains(AppleFoundationModel.assistantInstruction) ?? false)
    }

    func testEmptyPersonaFallsBackToTheBuiltInOne() {
        let prompt = AppleFoundationModel.assistantPrompt(persona: "")
        XCTAssertTrue(prompt.hasPrefix("You are JARVIS, a concise and helpful on-device assistant."))
    }

    func testPersonaBoxTrimsWhitespace() {
        let persona = OnDevicePersona()
        persona.text = "  You are JARVIS.\n"
        XCTAssertEqual(persona.text, "You are JARVIS.")
    }

    // MARK: - Catalogue

    func testCatalogueMarksAppleFMInstalledOnlyWhenAvailable() {
        let ready = OnDeviceModelCatalog.list(appleFM: .available)
        XCTAssertEqual(ready.first?.id, "apple-fm")
        XCTAssertTrue(ready.first?.installed ?? false)

        let blocked = OnDeviceModelCatalog.list(appleFM: .unavailable("deviceNotEligible"))
        XCTAssertFalse(blocked.first?.installed ?? true)
        XCTAssertEqual(blocked.first?.detail, "deviceNotEligible")
    }

    /// The MLX entries keep their ids so a user upgrading from the Flutter build
    /// still sees the model they had selected — but they can never be picked.
    func testMLXEntriesAreListedButNeverInstalled() {
        let models = OnDeviceModelCatalog.list(appleFM: .available)
        let mlx = models.filter { $0.engine == .mlx }
        XCTAssertFalse(mlx.isEmpty)
        XCTAssertTrue(mlx.allSatisfy { !$0.installed })
        XCTAssertEqual(OnDeviceModelCatalog.engine(for: "apple-fm"), .appleFM)
        XCTAssertEqual(OnDeviceModelCatalog.engine(for: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"), .mlx)
    }

    // MARK: - Helpers

    private func request(_ text: String) -> LocalRequest {
        LocalRequest(userText: text, surface: .chat, toolCatalogJSON: "[]", tier: .fullLocalFirst)
    }

    func testMLXRowsFollowTheInstalledProbe() {
        let models = OnDeviceModelCatalog.list(appleFM: .available,
                                               mlxInstalled: { $0.contains("0.5B") })
        let small = models.first { $0.id == "mlx-community/Qwen2.5-0.5B-Instruct-4bit" }!
        let big = models.first { $0.id == "mlx-community/Qwen2.5-1.5B-Instruct-4bit" }!
        XCTAssertTrue(small.installed)
        XCTAssertNil(small.reason)
        XCTAssertFalse(big.installed)
        XCTAssertTrue(big.detail.hasPrefix("Not downloaded"), big.detail)
    }
}
