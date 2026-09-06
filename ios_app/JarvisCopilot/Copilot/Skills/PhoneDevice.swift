import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The phone itself, exposed to the Jarvis bridge as one more `WearableDevice`.
///
/// This is what makes phone skills ride the existing plumbing untouched:
/// `BridgeClient.sendRegistration()` reads `DeviceRegistry.shared.allSkills()`
/// and `drainQueue`/`runInvoke` dispatch through
/// `DeviceRegistry.shared.invoke(skill:args:)`. Both find the phone's skills
/// here, filtered by the user's `skills_disabled` set, with no change to
/// `BridgeClient`.
@MainActor
final class PhoneDevice: WearableDevice {
    static let model = "iPhone"

    /// Fixed, because there is exactly one phone and its id has to survive
    /// relaunches — `DeviceRegistry.register` dedupes on this.
    let deviceID = "phone"

    /// Always true: the phone is not something we can lose the link to. (A BLE
    /// wearable can be out of range; this can't.)
    var isConnected: Bool { true }

    private let registry: SkillRegistry
    private let runner: InvokeRunner

    init(registry: SkillRegistry = .shared, runner: InvokeRunner = .shared) {
        self.registry = registry
        self.runner = runner
    }

    /// Only the skills the user has left switched on — a disabled skill is
    /// neither advertised nor dispatchable.
    var capabilities: [DeviceCapability] { registry.capabilities() }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "model": Self.model,
            "skills": registry.enabledNames,
            "disabled": registry.disabled.sorted(),
        ]
        #if canImport(UIKit)
        out["system"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
        return out
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        // Everything goes through the InvokeRunner so the disabled-skill ACL,
        // the pause switch, the foreground-defer rule and the log all apply
        // whichever path the invoke arrived on.
        let outcome = await runner.run(name, args)
        if let error = outcome.error {
            // The bridge turns a thrown error into `{"type":"error", …}`; a
            // returned `{error: …}` map would look like success.
            if error.hasPrefix("unknown skill") { throw DeviceError.unknownCommand(name) }
            throw SkillError.failed(error)
        }
        return outcome.result ?? [:]
    }
}
