import Foundation

/// The app-facing entry point to the on-device AI layer — the Swift equivalent of
/// `mobile_client/lib/services/on_device_ai.dart` (whose job was marshalling a
/// MethodChannel; here the engine is simply called directly).
///
/// One instance per app: the FoundationModels session it drives is warm, shared
/// state, so a second would fight the first for the ANE.
@MainActor
final class OnDeviceAI {

    static let shared = OnDeviceAI()

    let engine: any OnDeviceInferenceEngine
    let settings: LocalAiSettings
    private let personaBox: OnDevicePersona

    init(engine: (any OnDeviceInferenceEngine)? = nil,
         settings: LocalAiSettings? = nil,
         persona: OnDevicePersona = .shared) {
        self.engine = engine ?? AppleFMEngine.shared
        self.settings = settings ?? .shared
        self.personaBox = persona
    }

    // MARK: - Persona

    var persona: String { personaBox.text }

    /// Called once the server's active personality is known, so local replies
    /// sound like the same assistant.
    func setPersona(_ text: String) { personaBox.text = text }

    // MARK: - Model

    /// The ``OnDeviceModel`` the router and the chat handler talk to.
    var model: AppleFoundationModel {
        AppleFoundationModel(engine: engine, persona: personaBox)
    }

    func availability() async -> OnDeviceAvailability { await model.availability() }

    func listModels() async -> [LocalModelInfo] {
        OnDeviceModelCatalog.list(appleFM: await engine.availability())
    }

    /// Warm the engine for the selected model. Best-effort — a failure just means
    /// the first token is cold.
    func warmUp() async {
        try? await engine.load(modelID: settings.activeLocalModelID)
    }

    func cancel() async { await engine.cancel() }

    // MARK: - Generation

    /// Stream a free-form on-device answer (the debug Test box, and the full
    /// replies the router's `.directAnswer` asks for).
    func generate(_ text: String,
                  surface: VoiceSurface) -> AsyncThrowingStream<String, Error> {
        let request = LocalRequest(userText: text, surface: surface,
                                   toolCatalogJSON: "[]", tier: .fullLocalFirst)
        return model.generate(request)
    }

    /// Collect a full on-device reply. Never throws: an engine failure yields ""
    /// so the caller escalates to the server instead of showing an error.
    func generateAll(_ text: String, surface: VoiceSurface) async -> String {
        var out = ""
        do {
            for try await chunk in generate(text, surface: surface) { out += chunk }
        } catch {
            // A partial answer is still better than nothing; an empty one tells
            // the caller to escalate.
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat

    /// The handler `ChatStore(onDevice:)` takes. Built lazily so an app that never
    /// enables on-device AI never constructs a router.
    private(set) lazy var chatHandler: any OnDeviceChatHandler = OnDeviceChatBridge(
        router: LocalRouter(model: model, settings: settings),
        settings: settings,
        stream: { [weak self] text in
            self?.generate(text, surface: .chat)
                ?? AsyncThrowingStream { $0.finish() }
        },
        runTool: { name, args in await InvokeRunner.shared.run(name, args) })
}
