import Foundation

/// Metadata for one available local model. Port of `LocalModelInfo` in
/// `mobile_client/lib/services/on_device_ai_types.dart`.
struct LocalModelInfo: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let engine: OnDeviceEngineKind
    /// Ready to use right now (Apple FM is "installed" when the OS says the model
    /// is available; an MLX model would be installed once downloaded).
    let installed: Bool
    /// Approximate on-disk download size. 0 for Apple FM — the OS owns the weights.
    let sizeBytes: Int64
    /// Approximate peak RAM when loaded. 0 for Apple FM (not our allocation).
    let ramHintMB: Int
    /// Why it isn't usable, when it isn't.
    let reason: String?

    init(id: String, label: String, engine: OnDeviceEngineKind, installed: Bool,
         sizeBytes: Int64 = 0, ramHintMB: Int = 0, reason: String? = nil) {
        self.id = id
        self.label = label
        self.engine = engine
        self.installed = installed
        self.sizeBytes = sizeBytes
        self.ramHintMB = ramHintMB
        self.reason = reason
    }

    /// The settings row's second line.
    var detail: String {
        if installed {
            return ramHintMB > 0 ? "~\(ramHintMB) MB RAM" : "Installed"
        }
        if let reason, !reason.isEmpty { return reason }
        return sizeBytes > 0 ? "Not downloaded · \(sizeBytes / 1_000_000) MB" : "Not available"
    }
}

/// The local model catalogue. Port of the `catalog` in
/// `mobile_client/ios/Runner/OnDeviceAI/ModelManager.swift`. The MLX entries are
/// downloadable through ``MLXEngine`` / the `OnDeviceLLM` package.
enum OnDeviceModelCatalog {

    static let appleFMID = OnDeviceEngineKind.appleFM.rawValue

    struct Spec: Sendable {
        let id: String
        let label: String
        let engine: OnDeviceEngineKind
        let sizeBytes: Int64
        let ramHintMB: Int
    }

    static let specs: [Spec] = [
        Spec(id: appleFMID,
             label: "Apple Intelligence (on-device)",
             engine: .appleFM,
             sizeBytes: 0,          // bundled with the OS
             ramHintMB: 0),
        Spec(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
             label: "Qwen2.5 1.5B Instruct (4-bit)",
             engine: .mlx,
             sizeBytes: 1_050_000_000,
             ramHintMB: 1_400),
        Spec(id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
             label: "Llama 3.2 1B Instruct (4-bit)",
             engine: .mlx,
             sizeBytes: 730_000_000,
             ramHintMB: 1_100),
        Spec(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
             label: "Qwen2.5 0.5B Instruct (4-bit)",
             engine: .mlx,
             sizeBytes: 300_000_000,
             ramHintMB: 700),
    ]

    static func engine(for modelID: String) -> OnDeviceEngineKind {
        specs.first { $0.id == modelID }?.engine ?? .mlx
    }

    /// Render the catalogue against a live Apple-FM availability probe. MLX rows
    /// count as unavailable — see the two-argument overload for the real check.
    static func list(appleFM: OnDeviceEngineAvailability) -> [LocalModelInfo] {
        list(appleFM: appleFM, mlxInstalled: { _ in false })
    }

    /// `mlxInstalled` answers whether a downloadable model's weights are on disk.
    static func list(appleFM: OnDeviceEngineAvailability,
                     mlxInstalled: (String) -> Bool) -> [LocalModelInfo] {
        specs.map { spec in
            switch spec.engine {
            case .appleFM:
                return LocalModelInfo(id: spec.id, label: spec.label, engine: spec.engine,
                                      installed: appleFM.isAvailable,
                                      sizeBytes: spec.sizeBytes, ramHintMB: spec.ramHintMB,
                                      reason: appleFM.reason)
            case .mlx:
                return LocalModelInfo(id: spec.id, label: spec.label, engine: spec.engine,
                                      installed: mlxInstalled(spec.id),
                                      sizeBytes: spec.sizeBytes, ramHintMB: spec.ramHintMB,
                                      reason: nil)
            }
        }
    }
}
