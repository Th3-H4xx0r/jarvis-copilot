import Foundation
import Observation

/// The speech settings on screen: shared by the Speech engine page, the Live
/// sheet's Transcription choice, the Voice sheet and the Mac's voice panel.
///
/// Every change shows at once and is PUT at once; a refusal puts back what the
/// server holds and says why — the same shape as `LiveStore.save`.
@MainActor
@Observable
final class SpeechEngineStore {
    static let shared = SpeechEngineStore()

    private(set) var settings = SpeechSettings()
    private(set) var loaded = false
    private(set) var error = ""
    /// The Test button's answer, and whether it was a pass.
    private(set) var testMessage = ""
    private(set) var testPassed: Bool?
    private(set) var testing = false

    private let api: SpeechEngineAPI

    init(api: SpeechEngineAPI = SpeechEngineAPI()) {
        self.api = api
    }

    func load() async {
        do {
            settings = try await api.load()
            loaded = true
            error = ""
        } catch {
            self.error = apiErrorLine(error)
        }
    }

    func setSurface(_ name: String, to engine: String) async {
        guard settings.surface(name) != engine else { return }
        let old = settings.surface(name)
        settings.setSurface(name, engine)
        await commit(patch: ["surfaces": [name: engine]]) { $0.setSurface(name, old) }
    }

    func setSoniox<Value>(_ field: WritableKeyPath<SpeechSoniox, Value>, _ value: Value, key: String) async {
        let old = settings.soniox[keyPath: field]
        settings.soniox[keyPath: field] = value
        await commit(patch: ["soniox": [key: value]]) { $0.soniox[keyPath: field] = old }
    }

    /// Save a new key ("" removes it). The key is not kept here once it is sent.
    @discardableResult
    func saveKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let status = try await api.saveKey(trimmed)
            settings.keySet = status.set
            settings.keyHint = status.hint
            testMessage = ""
            testPassed = nil
            error = ""
            // Which engines can run changes with the key.
            await load()
            return true
        } catch {
            self.error = apiErrorLine(error)
            return false
        }
    }

    func test() async {
        testing = true
        defer { testing = false }
        do {
            let result = try await api.test()
            testPassed = result.ok
            testMessage = result.message
        } catch {
            testPassed = false
            testMessage = apiErrorLine(error)
        }
    }

    /// Save one change already on screen. A refusal puts back ONLY that field:
    /// restoring a whole snapshot would also undo — or resurrect — another
    /// save that overlapped this one.
    private func commit(patch: [String: Any], revert: (inout SpeechSettings) -> Void) async {
        do {
            let config = try await api.save(patch)
            settings.apply(config: config)
            error = ""
        } catch {
            revert(&settings)
            self.error = apiErrorLine(error)
        }
    }
}

extension SpeechEngineStore {
    /// Whether the server can hear with Soniox right now (it has a key).
    var sonioxReady: Bool { settings.engines.contains { $0.name == "soniox" && $0.available } }

    /// "Soniox" in a voice picker: this device sends its audio and the server
    /// hears it — so the server's voice engine is pointed at Soniox too, for
    /// every device that sends audio (a browser, the Pod) as well.
    func useSonioxForVoice() async {
        if !loaded { await load() }
        if settings.voice != "soniox" { await setSurface("voice", to: "soniox") }
    }
}
