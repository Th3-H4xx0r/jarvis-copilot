import XCTest
@testable import JarvisCopilot

/// Registry behaviour + the `skills_disabled` semantics ported from
/// `mobile_client/lib/services/credentials.dart`.
@MainActor
final class SkillRegistryTests: XCTestCase {

    private func skill(_ name: String) -> AnySkill {
        AnySkill(name: name, description: "desc for \(name)") { _ in ["ok": true] }
    }

    // MARK: catalogue

    func testRegisterKeepsOrderAndReplacesByName() {
        let r = SkillRegistry(store: MemoryKeyValueStore())
        r.register(skill("b"))
        r.register(skill("a"))
        XCTAssertEqual(r.all.map(\.name), ["b", "a"])
        XCTAssertEqual(r.names, ["a", "b"])           // names() sorts
        r.register(AnySkill(name: "b", description: "replaced") { _ in [:] })
        XCTAssertEqual(r.all.map(\.name), ["b", "a"]) // no duplicate
        XCTAssertEqual(r.find("b")?.description, "replaced")
    }

    func testFindReturnsNilForAnUnknownSkill() {
        let r = SkillRegistry(store: MemoryKeyValueStore(), skills: [skill("a")])
        XCTAssertNil(r.find("nope"))
    }

    func testManifestIsTheBridgeWireShape() throws {
        let r = SkillRegistry(store: MemoryKeyValueStore(), skills: [skill("a")])
        let entry = try XCTUnwrap(r.manifest().first)
        XCTAssertEqual(Set(entry.keys), ["name", "description", "input_schema"])
        XCTAssertEqual(entry["name"] as? String, "a")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(entry))
    }

    // MARK: enable / disable

    func testDisablingHidesASkillFromTheManifestAndCapabilities() {
        let r = SkillRegistry(store: MemoryKeyValueStore(), skills: [skill("a"), skill("b")])
        r.setEnabled(false, for: "a")
        XCTAssertFalse(r.isEnabled("a"))
        XCTAssertEqual(r.enabledNames, ["b"])
        XCTAssertEqual(r.manifest().compactMap { $0["name"] as? String }, ["b"])
        XCTAssertEqual(r.capabilities().map(\.name), ["b"])
        // …but it is still registered, so a settings screen can list it.
        XCTAssertNotNil(r.find("a"))
    }

    func testReEnablingRestoresIt() {
        let r = SkillRegistry(store: MemoryKeyValueStore(), skills: [skill("a")])
        r.setEnabled(false, for: "a")
        r.setEnabled(true, for: "a")
        XCTAssertEqual(r.enabledNames, ["a"])
    }

    func testGenerationBumpsOnCatalogueAndDisabledChanges() {
        let r = SkillRegistry(store: MemoryKeyValueStore())
        let start = r.generation
        r.register(skill("a"))
        XCTAssertGreaterThan(r.generation, start)
        let afterRegister = r.generation
        r.setEnabled(false, for: "a")
        XCTAssertGreaterThan(r.generation, afterRegister)
        // A no-op change doesn't bump (the bridge shouldn't re-register).
        let stable = r.generation
        r.setEnabled(false, for: "a")
        XCTAssertEqual(r.generation, stable)
    }

    // MARK: persistence

    func testDisabledSetPersistsUnderSkillsDisabled() throws {
        let store = MemoryKeyValueStore()
        let first = SkillRegistry(store: store, skills: [skill("a"), skill("b")])
        first.setEnabled(false, for: "b")

        let raw = try XCTUnwrap(store.string(SkillRegistry.disabledKey))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String])
        XCTAssertEqual(decoded, ["b"])

        // A fresh registry over the same store starts with the same set.
        let second = SkillRegistry(store: store, skills: [skill("a"), skill("b")])
        XCTAssertEqual(second.disabled, ["b"])
        XCTAssertEqual(second.enabledNames, ["a"])
    }

    func testSetDisabledReplacesTheWholeSet() {
        let store = MemoryKeyValueStore()
        let r = SkillRegistry(store: store, skills: [skill("a"), skill("b"), skill("c")])
        r.setDisabled(["a", "c"])
        XCTAssertEqual(r.enabledNames, ["b"])
        r.setDisabled([])
        XCTAssertEqual(r.enabledNames, ["a", "b", "c"])
    }

    /// The Dart original treated corrupt exactly like absent, which fails OPEN:
    /// one bad byte re-enabled every skill the user had switched off, and the
    /// next write overwrote their list with `[]`. Fail closed instead.
    func testACorruptStoredValueRefusesEverySkill() {
        for junk in ["not json", "{\"a\":1}", "[\"a\""] {
            let store = MemoryKeyValueStore([SkillRegistry.disabledKey: junk])
            let r = SkillRegistry(store: store, skills: [skill("a"), skill("b")])
            XCTAssertTrue(r.disabledUnreadable, junk)
            XCTAssertEqual(r.disabled, ["a", "b"], junk)
            XCTAssertFalse(r.isEnabled("a"), junk)
            XCTAssertTrue(r.enabledNames.isEmpty, junk)
            XCTAssertTrue(r.manifest().isEmpty, junk)
            // And the bad value is left alone — nothing auto-corrects it.
            XCTAssertEqual(store.string(SkillRegistry.disabledKey), junk)
        }
    }

    /// A dispatch attempt has to be refused too, not just hidden from the
    /// manifest — the server may still hold an older manifest.
    func testACorruptStoredValueAlsoRefusesDispatch() async {
        let store = MemoryKeyValueStore([SkillRegistry.disabledKey: "not json"])
        let registry = SkillRegistry(store: store, skills: [skill("a")])
        let runner = InvokeRunner(registry: registry, lifecycle: AppLifecycle(),
                                  pending: PendingActions(), notifier: MockNotifier(),
                                  store: MemoryKeyValueStore())
        let outcome = await runner.run("a", [:])
        XCTAssertEqual(outcome.error, "skill disabled by user")
    }

    /// An explicit user choice is what replaces the unreadable value.
    func testAnExplicitChoiceRecoversFromACorruptStoredValue() {
        let store = MemoryKeyValueStore([SkillRegistry.disabledKey: "not json"])
        let r = SkillRegistry(store: store, skills: [skill("a"), skill("b")])
        r.setDisabled(["a"])
        XCTAssertFalse(r.disabledUnreadable)
        XCTAssertEqual(r.disabled, ["a"])
        XCTAssertEqual(r.enabledNames, ["b"])
        XCTAssertEqual(store.string(SkillRegistry.disabledKey), "[\"a\"]")
    }

    func testTogglingOneSkillAlsoRecoversFromACorruptStoredValue() {
        let store = MemoryKeyValueStore([SkillRegistry.disabledKey: "not json"])
        let r = SkillRegistry(store: store, skills: [skill("a"), skill("b")])
        r.setEnabled(false, for: "a")
        XCTAssertFalse(r.disabledUnreadable)
        XCTAssertEqual(r.enabledNames, ["b"])
        XCTAssertEqual(store.string(SkillRegistry.disabledKey), "[\"a\"]")
    }

    func testAnAbsentOrBlankValueMeansNothingDisabled() {
        for store in [MemoryKeyValueStore(),
                      MemoryKeyValueStore([SkillRegistry.disabledKey: ""]),
                      MemoryKeyValueStore([SkillRegistry.disabledKey: "  \n"])] {
            let r = SkillRegistry(store: store, skills: [skill("a")])
            XCTAssertFalse(r.disabledUnreadable)
            XCTAssertEqual(r.disabled, [])
            XCTAssertTrue(r.isEnabled("a"))
        }
    }

    /// `generation` used to bump whether or not the write landed, so the bridge
    /// re-registered a manifest that no relaunch would reproduce.
    func testGenerationDoesNotBumpWhenTheWriteDidNotStick() {
        let store = RefusingKeyValueStore()
        let r = SkillRegistry(store: store, skills: [skill("a")])
        let before = r.generation
        var announcements = 0
        r.onChanged = { announcements += 1 }
        r.setEnabled(false, for: "a")
        XCTAssertEqual(r.generation, before, "nothing reached disk")
        XCTAssertEqual(announcements, 0, "and the bridge was not told to re-register")
        // The in-memory ACL is still enforced — refusing is the safe direction.
        XCTAssertFalse(r.isEnabled("a"))
    }

    // MARK: the real catalogue's schemas

    func testEverySkillHasAValidSchemaWithResolvableRequiredFields() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let skills = PhoneSkills.all(boundaries)
        XCTAssertFalse(skills.isEmpty)
        var seen = Set<String>()

        for skill in skills {
            XCTAssertFalse(skill.name.isEmpty)
            XCTAssertTrue(seen.insert(skill.name).inserted, "duplicate skill \(skill.name)")
            XCTAssertFalse(skill.description.isEmpty, skill.name)

            let schema = skill.inputSchema
            XCTAssertTrue(JSONSerialization.isValidJSONObject(schema),
                          "\(skill.name) schema is not JSON-encodable")
            XCTAssertEqual(schema["type"] as? String, "object", skill.name)
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for required in schema["required"] as? [String] ?? [] {
                XCTAssertNotNil(properties[required],
                                "\(skill.name) requires \"\(required)\" but doesn't declare it")
            }
            // A declared property has to be a schema object of its own.
            for (key, value) in properties {
                XCTAssertNotNil(value as? [String: Any], "\(skill.name).\(key)")
            }
        }
    }

    func testTheCatalogueCoversEverySkillTheFlutterClientAdvertised() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let names = Set(PhoneSkills.all(boundaries).map(\.name))
        for expected in [
            "open_url", "open_app", "notify", "clipboard_read", "clipboard_write",
            "share_text", "device_info", "battery_level", "vibrate", "get_location",
            "take_photo", "pick_photo", "text_to_speech", "play_audio", "set_alarm",
            "flashlight_on", "flashlight_off", "make_call", "record_audio",
            "read_contacts", "add_calendar_event", "list_calendar_events",
            "send_sms", "run_shortcut", "read_healthkit", "shortcuts_list",
            "create_shortcut", "phone_control", "phone_capabilities",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        // New in the native port.
        XCTAssertTrue(names.contains("share_image"))
    }

    func testForegroundRequiredFlagsMatchTheFlutterClient() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let byName = Dictionary(uniqueKeysWithValues: PhoneSkills.all(boundaries).map { ($0.name, $0) })
        for name in ["open_url", "open_app", "send_sms", "run_shortcut", "create_shortcut",
                     "phone_control"] {
            XCTAssertTrue(byName[name]?.requiresForeground ?? false, name)
        }
        for name in ["notify", "battery_level", "device_info", "clipboard_read",
                     "clipboard_write", "vibrate", "set_alarm", "read_healthkit",
                     "phone_capabilities", "shortcuts_list"] {
            XCTAssertFalse(byName[name]?.requiresForeground ?? true, name)
        }
    }
}
