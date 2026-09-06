import Foundation

/// One native skill this phone advertises to the Jarvis server.
///
/// Maps 1:1 onto a bridge "skill" (`{name, description, input_schema}`) — the
/// same wire shape `DeviceCapability` produces for the BLE wearables — and onto
/// the Flutter client's `SkillEntry` (`mobile_client/lib/skills/registry.dart`).
///
/// Only `run` is `@MainActor`: most implementations touch UIKit (pasteboard,
/// openURL, haptics, presenters) and the bridge dispatches invokes on the main
/// actor already. The metadata stays nonisolated so the catalogue, the registry
/// and the tests can read it from anywhere; platform work that belongs off the
/// main thread lives behind the `Sendable` boundary protocols in
/// `SkillBoundaries.swift`.
protocol LocalSkill {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments. Sent verbatim as `input_schema`.
    var inputSchema: [String: Any] { get }
    /// True for skills that open an app / URL / system UI. iOS refuses
    /// `UIApplication.open` from the background, so the invoke runner defers
    /// these and posts a local notification instead — see
    /// `shouldDeferToForeground`.
    var requiresForeground: Bool { get }
    @MainActor
    func run(_ args: [String: Any]) async throws -> [String: Any]
}

extension LocalSkill {
    var requiresForeground: Bool { false }

    /// The entry the bridge sends in its `register` frame.
    var manifest: [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema]
    }

    /// The same skill expressed for `DeviceRegistry`, so phone skills ride the
    /// existing `allSkills()` / `invoke(skill:args:)` path untouched.
    var capability: DeviceCapability {
        DeviceCapability(name: name, description: description, inputSchema: inputSchema)
    }
}

/// A skill built from a closure — the direct equivalent of Dart's `SkillEntry`,
/// which is what the factories in `SystemSkills`/`MediaSkills`/… produce. The
/// boundary a skill needs is captured when it's constructed, which is what makes
/// every one of them drivable from a mock in tests.
struct AnySkill: LocalSkill {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let requiresForeground: Bool

    private let body: @MainActor ([String: Any]) async throws -> [String: Any]

    init(name: String,
         description: String,
         inputSchema: [String: Any] = SkillSchema.empty,
         requiresForeground: Bool = false,
         run: @MainActor @escaping ([String: Any]) async throws -> [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.requiresForeground = requiresForeground
        self.body = run
    }

    @MainActor
    func run(_ args: [String: Any]) async throws -> [String: Any] {
        try await body(args)
    }
}

/// Why a skill refused. `errorDescription` is what the bridge sends back as the
/// `error` field, so it has to read as a sentence to the agent.
enum SkillError: LocalizedError, Equatable {
    /// Missing/unusable argument — the agent can fix this and retry.
    case badArgument(String)
    /// The user said no to a system permission prompt.
    case permissionDenied(String)
    /// Hardware or framework isn't there (no torch, HealthKit off, simulator).
    case unavailable(String)
    /// Ran but failed.
    case failed(String)
    /// Not in the catalogue, or switched off in Settings.
    case unknownSkill(String)
    case disabled(String)

    var errorDescription: String? {
        switch self {
        case .badArgument(let m):      return m
        case .permissionDenied(let m): return "\(m) permission denied"
        case .unavailable(let m):      return m
        case .failed(let m):           return m
        case .unknownSkill(let n):     return "unknown skill: \(n)"
        case .disabled(let n):         return "skill disabled by user: \(n)"
        }
    }
}

/// Shorthand for the "object with these properties" schemas every skill uses.
enum SkillSchema {
    static let empty: [String: Any] = ["type": "object"]

    static func object(_ properties: [String: [String: Any]] = [:],
                       required: [String] = []) -> [String: Any] {
        DeviceCapability.schema(properties, required: required)
    }

    static func string(_ description: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "string"]
        if let description { out["description"] = description }
        return out
    }

    static func integer(min: Int? = nil, max: Int? = nil, description: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "integer"]
        if let min { out["minimum"] = min }
        if let max { out["maximum"] = max }
        if let description { out["description"] = description }
        return out
    }

    static func number(min: Double? = nil, max: Double? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "number"]
        if let min { out["minimum"] = min }
        if let max { out["maximum"] = max }
        return out
    }

    static let boolean: [String: Any] = ["type": "boolean"]

    static func enumeration(_ values: [String], description: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "string", "enum": values]
        if let description { out["description"] = description }
        return out
    }
}
