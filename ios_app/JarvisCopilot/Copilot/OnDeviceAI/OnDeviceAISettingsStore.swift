import Foundation
import Observation
import OnDeviceLLM

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

    /// In-flight MLX downloads, model id → 0…1.
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var downloadError: String?

    @ObservationIgnored private let ai: OnDeviceAI
    @ObservationIgnored private var generateTask: Task<Void, Never>?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

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

    // MARK: - MLX downloads

    func download(_ model: LocalModelInfo) {
        guard model.engine == .mlx, !model.installed, downloads[model.id] == nil else { return }
        downloadError = nil
        downloadProgress[model.id] = 0
        let id = model.id
        downloads[id] = Task { @MainActor [weak self] in
            do {
                try await LocalLLM.shared.download(id) { p in
                    Task { @MainActor [weak self] in self?.downloadProgress[id] = p }
                }
                self?.downloadProgress[id] = nil
                await self?.refresh()
            } catch is CancellationError {
                self?.downloadProgress[id] = nil
            } catch {
                self?.downloadProgress[id] = nil
                self?.downloadError = error.localizedDescription
            }
            self?.downloads[id] = nil
        }
    }

    func cancelDownload(_ model: LocalModelInfo) {
        downloads[model.id]?.cancel()
        downloads[model.id] = nil
        downloadProgress[model.id] = nil
    }

    func delete(_ model: LocalModelInfo) {
        guard model.engine == .mlx else { return }
        Task { @MainActor in
            await MLXEngine.shared.unload()
            try? LocalLLM.delete(model.id)
            if settings.activeLocalModelID == model.id {
                settings.activeLocalModelID = OnDeviceModelCatalog.appleFMID
                settings.save()
            }
            await refresh()
        }
    }

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
