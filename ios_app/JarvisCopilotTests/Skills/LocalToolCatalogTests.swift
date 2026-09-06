import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/local_tool_catalog_test.dart`.
///
/// Uses its own `SkillRegistry` rather than the shared one — the Dart suite got
/// isolation for free (one isolate per test file); here it has to be explicit.
@MainActor
final class LocalToolCatalogTests: XCTestCase {

    private func skill(_ name: String) -> AnySkill {
        AnySkill(name: name, description: "desc for \(name)") { _ in ["ok": true] }
    }

    private func catalogue() -> (LocalToolCatalog, SkillRegistry) {
        let registry = SkillRegistry(store: MemoryKeyValueStore())
        // A real device-local skill (in the offline allow-list) and a real
        // registered skill that is NOT offline-capable (client-dispatchable).
        registry.register(skill("vibrate"))
        registry.register(skill("read_contacts"))
        let catalogue = LocalToolCatalog(registry: registry)
        catalogue.setServerTools([["name": "web_search", "description": "search the web"]])
        return (catalogue, registry)
    }

    func testClassOfTagsDeviceLocalClientDispatchableAndServerOnly() {
        let (cat, _) = catalogue()
        XCTAssertEqual(cat.classOf("vibrate"), .deviceLocal)
        XCTAssertEqual(cat.classOf("read_contacts"), .clientDispatchable)
        XCTAssertEqual(cat.classOf("web_search"), .serverOnly)
        // Unknown names default to serverOnly (safe → escalate).
        XCTAssertEqual(cat.classOf("totally_unknown"), .serverOnly)
    }

    func testBuildPromptCatalogListsOnlyExecutableDeviceSkills() throws {
        let (cat, _) = catalogue()
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(cat.buildPromptCatalog().utf8))
                as? [[String: Any]])
        let names = Set(json.compactMap { $0["name"] as? String })

        XCTAssertTrue(names.contains("vibrate"))
        XCTAssertTrue(names.contains("read_contacts"))
        // Server-only tools are deliberately NOT shown to the local model.
        XCTAssertFalse(names.contains("web_search"))
        // Entries carry only name + desc (no execClass in the prompt).
        XCTAssertEqual(Set(json[0].keys), ["name", "desc"])
    }

    func testPromptCatalogIsCappedAndDescriptionsAreShortened() throws {
        let registry = SkillRegistry(store: MemoryKeyValueStore())
        for i in 0..<10 {
            registry.register(AnySkill(name: "skill_\(i)",
                                       description: String(repeating: "x", count: 200)) { _ in [:] })
        }
        let cat = LocalToolCatalog(registry: registry, maxTools: 3)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(cat.buildPromptCatalog().utf8))
                as? [[String: Any]])
        XCTAssertEqual(json.count, 3)
        XCTAssertEqual((json[0]["desc"] as? String)?.count, 80)
    }

    func testEveryOfflineSkillNameStillClassifiesAsDeviceLocalInTheRealCatalogue() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let registry = SkillRegistry(store: MemoryKeyValueStore())
        registry.register(PhoneSkills.all(boundaries))
        let cat = LocalToolCatalog(registry: registry)
        // Names the catalogue calls "runs fully on device" must actually exist,
        // otherwise the router silently escalates everything.
        for name in ["set_alarm", "vibrate", "play_audio", "flashlight_on", "flashlight_off",
                     "notify", "battery_level", "device_info", "clipboard_read",
                     "clipboard_write", "get_location", "phone_control", "create_shortcut",
                     "run_shortcut", "text_to_speech"] {
            XCTAssertEqual(cat.classOf(name), .deviceLocal, name)
        }
        // Reading personal data is dispatchable but not "offline instant".
        XCTAssertEqual(cat.classOf("read_contacts"), .clientDispatchable)
        XCTAssertEqual(cat.classOf("send_sms"), .clientDispatchable)
    }
}
