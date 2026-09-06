import Foundation
import Observation

/// State behind ``OnDeviceAISettingsPage``: the persisted ``LocalAiSettings``, a
/// live availability probe, the model catalogue and the debug generate box.
///
/// Port of the state half of `mobile_client/lib/pages/ondevice_ai_settings_page.dart`.
/// Every mutation persists immediately (the Flutter page called `_save()` from
/// each `onChanged`), so nothing is lost if the user backs out mid-screen.
@MainActor
@Observable
final class OnDeviceAISettingsStore {

    let settings: LocalAiSettings

    private(set) var availability: OnDeviceAvailability?
    private(set) var models: [LocalModelInfo] = []
    private(set) var loading = true

    // Debug generate box.
    var prompt = ""
    private(set) var output = ""
    private(set) var running = false

    @ObservationIgnored private let ai: OnDeviceAI
    @ObservationIgnored private var generateTask: Task<Void, Never>?

    init(ai: OnDeviceAI? = nil, settings: LocalAiSettings? = nil) {
        let ai = ai ?? OnDeviceAI.shared
        self.ai = ai
        self.settings = settings ?? ai.settings
    }

    deinit { generateTask?.cancel() }

    // MARK: - Loading

    /// Read persisted preferences, then probe the engine. Split so the toggles
    /// render with the right values before the (slower) availability check lands.
    func load() async {
        settings.load()
        await refresh()
    }

    func refresh() async {
        let availability = await ai.availability()
        let models = await ai.listModels()
        self.availability = availability
        self.models = models
        loading = false
    }

    // MARK: - Mutations
    //
    // Each writes through to the key-value store immediately.

    func setTier(_ tier: LocalAiTier) { settings.tier = tier; settings.save() }
    func setChatEnabled(_ on: Bool) { settings.chatEnabled = on; settings.save() }
    func setVoiceEnabled(_ on: Bool) { settings.voiceEnabled = on; settings.save() }
    func setConfirmLocalActions(_ on: Bool) { settings.confirmLocalActions = on; settings.save() }
    func setCommandShortCircuit(_ on: Bool) { settings.commandShortCircuit = on; settings.save() }
    func setShowBadge(_ on: Bool) { settings.showBadge = on; settings.save() }

    /// Only an installed model can be selected — picking one that isn't there
    /// would leave the router pointing at an engine that always fails.
    func selectModel(_ model: LocalModelInfo) {
        guard model.installed else { return }
        settings.activeLocalModelID = model.id
        settings.save()
    }

    var activeModelID: String { settings.activeLocalModelID }

    /// One-line summary for the availability card.
    var availabilitySummary: String {
        if loading { return "Checking on-device engine…" }
        guard let availability else { return "Unavailable: unknown" }
        return availability.available
            ? "On-device engine ready (\(availability.engine))"
            : "Unavailable: \(availability.reason ?? "unknown")"
    }

    var isReady: Bool { availability?.available == true }

    // MARK: - Debug generate

    /// Stream the raw engine output for `prompt` — bypasses the router entirely,
    /// so it answers "is the engine working at all?".
    func runDebugGenerate() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        output = ""
        running = true
        generateTask?.cancel()
        let ai = ai
        generateTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in ai.generate(text, surface: .chat) {
                    guard let self, !Task.isCancelled else { return }
                    self.output += chunk
                }
            } catch {
                self?.output += "\n[error: \(error.localizedDescription)]"
            }
            self?.running = false
        }
    }

    func cancelDebugGenerate() {
        generateTask?.cancel()
        generateTask = nil
        running = false
        Task { await ai.cancel() }
    }
}
