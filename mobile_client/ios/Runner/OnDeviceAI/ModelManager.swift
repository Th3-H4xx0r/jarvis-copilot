import Foundation

#if canImport(Hub)
import Hub
#endif

// MARK: - ModelManager
//
// The single source of truth for which on-device models exist, their install
// state, and the bytes they occupy. It also performs (or stubs) downloads from
// the Hugging Face Hub and enforces a one-model-at-a-time memory guard so two
// multi-hundred-MB models can't be resident at once.
//
// HF download uses `swift-transformers`' `Hub` when importable; otherwise a
// clearly-stubbed async reports synthetic progress and writes a marker file so
// the rest of the flow (install-check, delete, storage accounting) still works
// end-to-end for testing before the package is wired in.

final class ModelManager {

    static let shared = ModelManager()

    /// Apple FM's pseudo-model id. Always "installed" — the OS owns the weights.
    static let appleFMId = "apple-fm"

    private init() {}

    // MARK: Curated catalog

    /// Static metadata for each curated model. `sizeBytes`/`ramHintMb` are
    /// approximate (4-bit quantized) and used by the UI for download sizing and
    /// the memory guard.
    private struct ModelSpec {
        let id: String
        let label: String
        let engine: String        // "apple-fm" | "mlx"
        let sizeBytes: Int64       // approx on-disk download size
        let ramHintMb: Int         // approx peak RAM when loaded
    }

    private let catalog: [ModelSpec] = [
        ModelSpec(
            id: appleFMId,
            label: "Apple Intelligence (on-device)",
            engine: "apple-fm",
            sizeBytes: 0,           // bundled with the OS
            ramHintMb: 0
        ),
        ModelSpec(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            label: "Qwen2.5 1.5B Instruct (4-bit)",
            engine: "mlx",
            sizeBytes: 1_050_000_000,   // ~1.0 GB
            ramHintMb: 1_400
        ),
        ModelSpec(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            label: "Llama 3.2 1B Instruct (4-bit)",
            engine: "mlx",
            sizeBytes: 730_000_000,     // ~0.7 GB
            ramHintMb: 1_100
        ),
        ModelSpec(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            label: "Qwen2.5 0.5B Instruct (4-bit)",
            engine: "mlx",
            sizeBytes: 300_000_000,     // ~0.3 GB
            ramHintMb: 700
        ),
    ]

    // MARK: Storage layout

    /// Root under Application Support where MLX weights live, e.g.
    /// `…/Application Support/OnDeviceModels/mlx-community__Qwen2.5-1.5B-Instruct-4bit/`.
    private var modelsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OnDeviceModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Per-model directory. Repo ids contain `/`, which is illegal in a path
    /// component, so we encode it as `__`.
    private func dir(for modelId: String) -> URL {
        let safe = modelId.replacingOccurrences(of: "/", with: "__")
        return modelsRoot.appendingPathComponent(safe, isDirectory: true)
    }

    // MARK: Install state

    /// Apple FM is always installed; an MLX model is installed when its
    /// directory exists and is non-empty.
    func isInstalled(_ modelId: String) -> Bool {
        if modelId == Self.appleFMId { return true }
        let d = dir(for: modelId)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: d.path) else {
            return false
        }
        return !contents.isEmpty
    }

    /// Bytes currently occupied on disk by a model (0 for Apple FM / not
    /// installed).
    func installedSizeBytes(_ modelId: String) -> Int64 {
        guard modelId != Self.appleFMId else { return 0 }
        return Self.directorySize(dir(for: modelId))
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Catalog → channel dicts

    /// The `[ [String:Any] ]` payload for the Dart `listModels()` call.
    func listModels() -> [[String: Any]] {
        catalog.map { spec in
            let installed = isInstalled(spec.id)
            return [
                "id": spec.id,
                "label": spec.label,
                "engine": spec.engine,
                "installed": installed,
                "sizeBytes": installed && spec.engine == "mlx"
                    ? max(spec.sizeBytes, installedSizeBytes(spec.id))
                    : spec.sizeBytes,
                "ramHintMb": spec.ramHintMb,
            ]
        }
    }

    func engine(for modelId: String) -> String {
        catalog.first(where: { $0.id == modelId })?.engine ?? "mlx"
    }

    func ramHintMb(for modelId: String) -> Int {
        catalog.first(where: { $0.id == modelId })?.ramHintMb ?? 0
    }

    // MARK: Download

    /// In-flight download tasks keyed by model id, so `cancelDownload` can
    /// abort them.
    private var downloads: [String: Task<Void, Error>] = [:]

    /// Download `modelId`'s weights, invoking `onProgress` (0…1) as bytes
    /// arrive and `onDone`/`onError` at the end. Returns immediately; work runs
    /// on a detached Task tracked for cancellation.
    func download(
        modelId: String,
        onProgress: @escaping (Double) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard modelId != Self.appleFMId else {
            // Nothing to fetch — already "installed".
            onProgress(1.0); onDone(); return
        }
        // Coalesce duplicate requests.
        if downloads[modelId] != nil { return }

        let task = Task<Void, Error> { [weak self] in
            guard let self = self else { return }
            do {
                try await self.performDownload(modelId: modelId, onProgress: onProgress)
                try Task.checkCancellation()
                await MainActor.run { onDone() }
            } catch is CancellationError {
                // Caller already knows; nothing to report.
            } catch {
                await MainActor.run { onError(error.localizedDescription) }
            }
            self.downloads[modelId] = nil
        }
        downloads[modelId] = task
    }

    func cancelDownload(modelId: String) {
        downloads[modelId]?.cancel()
        downloads[modelId] = nil
    }

    #if canImport(Hub)

    /// Real HF Hub snapshot download via swift-transformers.
    private func performDownload(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        let hub = HubApi(downloadBase: modelsRoot)
        let repo = Hub.Repo(id: modelId)
        // Grab the weight + tokenizer + config glob MLX needs.
        let patterns = ["*.safetensors", "*.json", "*.txt", "tokenizer.model", "*.tiktoken"]
        _ = try await hub.snapshot(from: repo, matching: patterns) { progress in
            onProgress(progress.fractionCompleted)
        }
        try Task.checkCancellation()
        onProgress(1.0)
    }

    #else

    /// Stub download: no package yet, so simulate progress and drop a marker so
    /// `isInstalled` flips true and the rest of the flow can be exercised.
    private func performDownload(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        let d = dir(for: modelId)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for step in 1...20 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            onProgress(Double(step) / 20.0)
        }
        // Marker so install-check passes; real weights arrive once Hub is wired.
        let marker = d.appendingPathComponent(".stub-download")
        try "stub: \(modelId)\n".data(using: .utf8)?.write(to: marker)
        onProgress(1.0)
    }

    #endif

    // MARK: Delete

    /// Remove a model's on-disk weights. No-op for Apple FM.
    @discardableResult
    func delete(modelId: String) -> Bool {
        guard modelId != Self.appleFMId else { return false }
        if loadedModelId == modelId { loadedModelId = nil }
        let d = dir(for: modelId)
        do {
            if FileManager.default.fileExists(atPath: d.path) {
                try FileManager.default.removeItem(at: d)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Single-loaded-model memory guard

    /// The one model currently resident in memory (loaded into an engine).
    private(set) var loadedModelId: String?

    /// Optional hook the plugin sets so a memory warning can evict the loaded
    /// model by unloading its engine. Returns nothing; the manager just clears
    /// its bookkeeping after invoking it.
    var evictionHook: (() -> Void)?

    /// Record that `modelId` is now the (single) resident model. Callers should
    /// unload any previous model first; we also surface the previous id so the
    /// plugin can tear down the old engine.
    @discardableResult
    func markLoaded(_ modelId: String) -> String? {
        let previous = loadedModelId
        loadedModelId = modelId
        return (previous == modelId) ? nil : previous
    }

    func markUnloaded() {
        loadedModelId = nil
    }

    /// Wire this up to `UIApplication.didReceiveMemoryWarningNotification` from
    /// the plugin. Evicts the resident model to reclaim RAM.
    func handleMemoryWarning() {
        guard loadedModelId != nil else { return }
        evictionHook?()
        loadedModelId = nil
    }
}
