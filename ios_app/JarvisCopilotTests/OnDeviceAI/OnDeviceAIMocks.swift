import Foundation
@testable import JarvisCopilot

// Fakes for the on-device AI boundary, so the router, the chat handler and the
// settings store can all be exercised with no Apple Intelligence, no engine and
// no skills registry.

/// A hand-driven ``OnDeviceInferenceEngine``. An `actor` because the real engine
/// is one — that's what makes the availability matrix meaningful.
actor FakeOnDeviceEngine: OnDeviceInferenceEngine {

    nonisolated let id: String

    private var availabilityValue: OnDeviceEngineAvailability
    /// Deltas handed to `onToken`, in order.
    private var chunks: [String]
    private var generateError: Error?
    private var loadError: Error?

    private(set) var availabilityCalls = 0
    private(set) var generateCalls = 0
    private(set) var cancelCalls = 0
    private(set) var loadedModelIDs: [String] = []
    private(set) var lastRequest: OnDeviceGenRequest?

    init(id: String = "apple-fm",
         availability: OnDeviceEngineAvailability = .available,
         chunks: [String] = [],
         generateError: Error? = nil,
         loadError: Error? = nil) {
        self.id = id
        self.availabilityValue = availability
        self.chunks = chunks
        self.generateError = generateError
        self.loadError = loadError
    }

    func setAvailability(_ value: OnDeviceEngineAvailability) { availabilityValue = value }
    func setChunks(_ value: [String]) { chunks = value }
    func setGenerateError(_ value: Error?) { generateError = value }

    func availability() async -> OnDeviceEngineAvailability {
        availabilityCalls += 1
        return availabilityValue
    }

    func load(modelID: String) async throws {
        loadedModelIDs.append(modelID)
        if let loadError { throw loadError }
    }

    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        generateCalls += 1
        lastRequest = request
        if let generateError { throw generateError }
        var out = ""
        for chunk in chunks {
            onToken(chunk)
            out += chunk
        }
        return out
    }

    func cancel() async { cancelCalls += 1 }
}

/// Runs (or refuses) a tool without touching `SkillRegistry`.
@MainActor
final class FakeOnDeviceToolRunner {
    var outcome: InvokeRunner.Outcome = .ok(["ok": true])
    private(set) var calls: [(name: String, args: [String: Any])] = []

    func run(_ name: String, _ args: [String: Any]) async -> InvokeRunner.Outcome {
        calls.append((name, args))
        return outcome
    }
}

/// `LocalAiSettings` on an in-memory store, with the on-device layer switched on.
@MainActor
func onDeviceSettings(tier: LocalAiTier = .routerCommands,
                      chat: Bool = true,
                      voice: Bool = true,
                      store: KeyValueStore = MemoryKeyValueStore()) -> LocalAiSettings {
    let settings = LocalAiSettings(store: store)
    settings.tier = tier
    settings.chatEnabled = chat
    settings.voiceEnabled = voice
    return settings
}

/// A stream that yields `chunks` then finishes, or throws `error` immediately.
func onDeviceStream(_ chunks: [String],
                    error: Error? = nil) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        if let error {
            continuation.finish(throwing: error)
            return
        }
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}
