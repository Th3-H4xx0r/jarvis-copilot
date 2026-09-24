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
        var next = settings
        next.setSurface(name, engine)
        await commit(next, patch: ["surfaces": [name: engine]])
    }

    func setSoniox<Value>(_ field: WritableKeyPath<SpeechSoniox, Value>, _ value: Value, key: String) async {
        var next = settings
        next.soniox[keyPath: field] = value
        await commit(next, patch: ["soniox": [key: value]])
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

    private func commit(_ next: SpeechSettings, patch: [String: Any]) async {
        let before = settings
        settings = next
        do {
            let config = try await api.save(patch)
            settings.apply(config: config)
            error = ""
        } catch {
            settings = before
            self.error = apiErrorLine(error)
        }
    }
}
