import Foundation

/// The catalogue surface `LocalRouter` depends on. Implemented by
/// `LocalToolCatalog` and faked in tests.
@MainActor
protocol ToolCatalog {
    /// Compact JSON the local model sees: `[{"name","desc"}, …]`.
    func buildPromptCatalog() throws -> String
    /// Where a tool by `name` actually runs.
    func classOf(_ name: String) -> ToolExecClass
}

/// Assembles the tool list the on-device model is shown: device-local skills
/// (from `SkillRegistry`) merged with the full server tool list (cached from
/// `GET /api/tools/catalog`). Each tool is tagged with a `ToolExecClass` so the
/// router knows whether the client can run it locally or must escalate.
///
/// Port of `mobile_client/lib/services/local_tool_catalog.dart`.
@MainActor
final class LocalToolCatalog: ToolCatalog {
    private let api: JarvisAPI?
    private let registry: SkillRegistry
    private let maxTools: Int

    /// Cached server tools: `[{name, description, toolset, schema}]`.
    private var serverTools: [[String: Any]] = []
    private var fetchedAt: Date?

    init(api: JarvisAPI? = nil, registry: SkillRegistry = .shared, maxTools: Int = 64) {
        self.api = api
        self.registry = registry
        self.maxTools = maxTools
    }

    /// Device skills that run fully on-device/offline (instant). Names MUST
    /// match the real registry entries. Anything else in the registry is
    /// client-dispatchable: the InvokeRunner can run it but it may hop the
    /// bridge / need the network.
    private static let offlineSkillNames: Set<String> = [
        "set_alarm",
        "vibrate",
        "play_audio",
        "flashlight_on",
        "flashlight_off",
        "set_volume",
        "adjust_volume",
        "notify",
        "battery_level",
        "device_info",
        "clipboard_read",
        "clipboard_write",
        "get_location",
        "phone_control",
        "create_shortcut",
        "run_shortcut",
        "text_to_speech",
    ]

    /// Refresh the cached server tool list. Safe to call opportunistically; a
    /// failure leaves the previous cache (or an empty one) in place.
    func refresh(ttl: TimeInterval = 6 * 60 * 60) async {
        guard let api else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl, !serverTools.isEmpty {
            return
        }
        do {
            let body = try await api.get("/api/tools/catalog").object()
            if let raw = body["tools"] as? [[String: Any]] {
                serverTools = raw
                fetchedAt = Date()
            }
        } catch {
            // A stale (or empty) catalogue just means more escalation, which is
            // the safe direction.
        }
    }

    /// Test seam: inject a server tool list without hitting the network.
    func setServerTools(_ tools: [[String: Any]]) {
        serverTools = tools
        fetchedAt = Date()
    }

    private func isServerTool(_ name: String) -> Bool {
        serverTools.contains { SkillArgs.string($0, "name") == name }
    }

    func classOf(_ name: String) -> ToolExecClass {
        if registry.find(name) != nil {
            return Self.offlineSkillNames.contains(name) ? .deviceLocal : .clientDispatchable
        }
        if isServerTool(name) { return .serverOnly }
        // Unknown name → safest is to escalate.
        return .serverOnly
    }

    func buildPromptCatalog() throws -> String {
        // Only show the model what it can ACTUALLY execute on-device (the device
        // skills). Server-only tools are deliberately NOT listed — otherwise the
        // small model thinks it can fetch weather/calendar/email itself and
        // fabricates results instead of escalating. Anything not listed →
        // escalate.
        var entries: [[String: String]] = []
        var seen = Set<String>()
        for skill in registry.all where seen.insert(skill.name).inserted {
            entries.append(["name": skill.name, "desc": Self.short(skill.description)])
        }
        if entries.count > maxTools { entries.removeSubrange(maxTools..<entries.count) }
        let data = try JSONSerialization.data(withJSONObject: entries)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func short(_ s: String, max: Int = 80) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count <= max ? one : String(one.prefix(max - 1)) + "…"
    }
}
