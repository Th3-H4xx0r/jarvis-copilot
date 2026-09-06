import Foundation

/// Process-wide catalogue of the native skills this phone advertises.
///
/// Registration order is preserved (Swift dictionaries are unordered, Dart maps
/// are insertion-ordered and the Flutter manifest relied on that), and a
/// re-register replaces the entry with the same name — same as
/// `SkillRegistry.register` in `mobile_client/lib/skills/registry.dart`.
///
/// The disabled set is the `skills_disabled` preference from
/// `services/credentials.dart`: a JSON array of skill names the user switched
/// off. Semantics ported verbatim — absent/blank/corrupt means "nothing
/// disabled", a disabled skill is neither advertised nor dispatchable.
@MainActor
final class SkillRegistry {
    static let shared = SkillRegistry()

    /// Same key the Flutter client used, so a shared server sees the same set.
    static let disabledKey = "skills_disabled"

    private let store: any KeyValueStore

    /// Where this registry persists. `InvokeRunner` defaults to the same store
    /// so the skill ACL and the pause kill switch live together: isolating one
    /// in a test isolates both, and neither leaks into `UserDefaults.standard`.
    var preferences: any KeyValueStore { store }

    private var order: [String] = []
    private var byName: [String: any LocalSkill] = [:]
    private var disabledNames: Set<String>

    /// True when `skills_disabled` held something we couldn't parse.
    ///
    /// The Dart original treated corrupt exactly like absent, which fails OPEN:
    /// one bad byte in the preference re-enabled every skill the user had
    /// switched off, silently and permanently (the next `persist()` overwrote
    /// the value with `[]`). We fail CLOSED instead — nothing dispatches until
    /// the user makes a new choice, which is also what replaces the bad value.
    private(set) var disabledUnreadable = false

    /// Bumped whenever the catalogue or the disabled set changes, so the bridge
    /// knows to re-register and the Skills page can observe it.
    private(set) var generation = 0

    /// Called on every `generation` bump. `AppServices` points this at
    /// `BridgeClient.sendRegistration()` so switching a skill off in the Skills
    /// tab actually leaves the manifest the server is holding — otherwise the ACL
    /// only takes effect on the next reconnect.
    var onChanged: (() -> Void)?

    init(store: any KeyValueStore = UserDefaults.standard, skills: [any LocalSkill] = []) {
        self.store = store
        let raw = store.string(Self.disabledKey)
        if let decoded = Self.decodeDisabled(raw) {
            self.disabledNames = decoded
        } else {
            self.disabledNames = []
            self.disabledUnreadable = true
            JcLog.skills.error(
                "\(Self.disabledKey, privacy: .public) is unreadable — every skill is refused until the user sets it again")
        }
        for skill in skills { register(skill) }
    }

    // MARK: Catalogue

    func register(_ skill: any LocalSkill) {
        if byName[skill.name] == nil { order.append(skill.name) }
        byName[skill.name] = skill
        bumpGeneration()
    }

    func register(_ skills: [any LocalSkill]) {
        for skill in skills { register(skill) }
    }

    func find(_ name: String) -> (any LocalSkill)? { byName[name] }

    /// Every registered skill, in registration order.
    var all: [any LocalSkill] { order.compactMap { byName[$0] } }

    /// Sorted names (Dart's `names()` sorts).
    var names: [String] { byName.keys.sorted() }

    /// Only the skills the user has left switched on.
    var enabled: [any LocalSkill] { all.filter { isEnabled($0.name) } }

    var enabledNames: [String] { names.filter(isEnabled) }

    /// The manifest the bridge sends in its `register` frame.
    func manifest() -> [[String: Any]] { enabled.map(\.manifest) }

    /// The same catalogue as `DeviceCapability` values, for `DeviceRegistry`.
    func capabilities() -> [DeviceCapability] { enabled.map(\.capability) }

    // MARK: Enable / disable (persisted)

    /// What `InvokeRunner` checks before dispatching. With an unreadable ACL
    /// that is EVERY skill: we can't prove the user left this one on.
    var disabled: Set<String> { disabledUnreadable ? Set(names) : disabledNames }

    func isEnabled(_ name: String) -> Bool {
        !disabledUnreadable && !disabledNames.contains(name)
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        let recovered = clearUnreadable()
        let changed = enabled ? disabledNames.remove(name) != nil
                              : disabledNames.insert(name).inserted
        guard changed || recovered else { return }
        persist()
    }

    /// Replace the whole disabled set (what a settings screen saves).
    func setDisabled(_ names: Set<String>) {
        let recovered = clearUnreadable()
        guard names != disabledNames || recovered else { return }
        disabledNames = names
        persist()
    }

    /// An explicit user choice is the only thing that replaces an unreadable
    /// stored ACL — nothing auto-corrects it, so a transient read failure can't
    /// quietly overwrite a set the user spent time on.
    private func clearUnreadable() -> Bool {
        guard disabledUnreadable else { return false }
        disabledUnreadable = false
        return true
    }

    private func persist() {
        // Sorted so the stored value is stable across launches (Set order isn't).
        let list = disabledNames.sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else {
            JcLog.skills.error("could not encode \(Self.disabledKey, privacy: .public)")
            return
        }
        store.set(json, forKey: Self.disabledKey)
        // Read back before telling the bridge to re-register: `generation` used
        // to bump whether or not the write landed, so a refused write left the
        // server holding a manifest that no relaunch would reproduce.
        guard store.string(Self.disabledKey) == json else {
            JcLog.skills.error("\(Self.disabledKey, privacy: .public) did not persist")
            return
        }
        bumpGeneration()
    }

    private func bumpGeneration() {
        generation += 1
        onChanged?()
    }

    /// Empty set for "absent/blank" (the user has disabled nothing), nil for
    /// "there was something there and it didn't parse" — the caller fails closed
    /// on nil rather than treating a corrupt ACL as an empty one.
    private static func decodeDisabled(_ raw: String?) -> Set<String>? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let list = parsed as? [Any] else { return nil }
        return Set(list.map { SkillArgs.text($0) }.filter { !$0.isEmpty })
    }
}
