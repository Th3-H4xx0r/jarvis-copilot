import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/profiles_test.dart`, case for case, plus the
/// endpoint and store behaviour from `profiles_page.dart`.
final class ProfilesTests: XCTestCase {

    // MARK: parseProfiles

    func testParsesTheProfilesActiveShape() {
        let data: JSONObject = [
            "profiles": [
                ["name": "default", "path": "/home/.jc", "model": "gpt", "provider": "openai"],
                ["name": "coder", "path": "/home/.jc/profiles/coder"],
            ],
            "active": "coder",
        ]
        let out = parseProfiles(data)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].name, "default")
        XCTAssertEqual(out[0].model, "gpt")
        XCTAssertEqual(out[0].provider, "openai")
        XCTAssertEqual(out[1].name, "coder")
    }

    func testToleratesABareListWithNoWrappingMap() {
        let out = parseProfiles([["name": "a"], ["name": "b"]])
        XCTAssertEqual(out.map(\.name), ["a", "b"])
    }

    func testDropsNonMapEntries() {
        let out = parseProfiles(["profiles": [["name": "ok"], "garbage", 42]] as JSONObject)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "ok")
    }

    func testEmptyOrMalformedInputsYieldAnEmptyList() {
        XCTAssertTrue(parseProfiles(JSONObject()).isEmpty)
        XCTAssertTrue(parseProfiles(nil).isEmpty)
        XCTAssertTrue(parseProfiles(["profiles": NSNull()] as JSONObject).isEmpty)
        XCTAssertTrue(parseProfiles(["profiles": "nope"] as JSONObject).isEmpty)
        XCTAssertTrue(parseProfiles("totally wrong").isEmpty)
    }

    // MARK: activeName

    func testReadsTheActiveKeyFromTheListResponse() {
        XCTAssertEqual(activeProfileName(["profiles": [], "active": "coder"] as JSONObject), "coder")
    }

    func testReadsTheNameKeyFromTheActiveProfileResponse() {
        XCTAssertEqual(activeProfileName(["name": "default", "path": "/x"] as JSONObject), "default")
    }

    func testSwitchResponseActiveKeyConfirmsTheNewProfile() {
        let switchResponse: JSONObject = [
            "profiles": [["name": "coder"]],
            "active": "coder",
            "default_model": "gpt",
        ]
        XCTAssertEqual(activeProfileName(switchResponse), "coder")
    }

    func testMissingOrMalformedInputsYieldEmptyString() {
        XCTAssertEqual(activeProfileName(JSONObject()), "")
        XCTAssertEqual(activeProfileName(nil), "")
        XCTAssertEqual(activeProfileName("nope"), "")
        XCTAssertEqual(activeProfileName(["active": NSNull()] as JSONObject), "")
    }

    // MARK: Profile flags (profiles_page logic)

    func testDefaultDetectionAndDeletability() {
        let named = Profile(json: ["name": "default"])
        XCTAssertTrue(named.isDefault)
        XCTAssertFalse(named.canDelete(activeName: "coder"))

        let flagged = Profile(json: ["name": "base", "is_default": true])
        XCTAssertTrue(flagged.isDefault)

        let coder = Profile(json: ["name": "coder"])
        XCTAssertFalse(coder.isDefault)
        XCTAssertFalse(coder.canDelete(activeName: "coder"), "the active profile can't be deleted")
        XCTAssertTrue(coder.canDelete(activeName: "default"))
    }

    func testGatewayLabelAndTone() {
        let running = Profile(json: ["name": "a", "gateway_running": true])
        XCTAssertEqual(running.gatewayLabel, "GATEWAY RUNNING")
        XCTAssertEqual(running.gatewayTone, .primaryBlue)

        let idle = Profile(json: ["name": "b"])
        XCTAssertEqual(idle.gatewayLabel, "GATEWAY IDLE")
        XCTAssertEqual(idle.gatewayTone, .muted)
    }

    func testModelAndProviderAliases() {
        let profile = Profile(json: ["name": "a", "default_model": "sonnet",
                                     "model_provider": "anthropic"])
        XCTAssertEqual(profile.model, "sonnet")
        XCTAssertEqual(profile.provider, "anthropic")
    }

    // MARK: API requests

    func testListReturnsProfilesAndActive() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["profiles": [["name": "default"], ["name": "coder"]],
                                 "active": "coder"])
        let result = try await ProfilesAPI(api: api).list()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/profiles")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(result.profiles.map(\.name), ["default", "coder"])
        XCTAssertEqual(result.active, "coder")
    }

    func testActiveHitsTheProfileActiveEndpoint() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["name": "coder", "path": "/x"])
        let body = try await ProfilesAPI(api: api).active()
        XCTAssertEqual(transport.lastPath, "/api/profile/active")
        XCTAssertEqual(activeProfileName(body), "coder")
    }

    func testSwitchPostsTheName() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["active": "coder"])
        let body = try await ProfilesAPI(api: api).switchTo("coder")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/profile/switch")
        assertJSONEqual(transport.lastBody(), ["name": "coder"])
        XCTAssertEqual(activeProfileName(body), "coder")
    }

    func testCreateAndDeleteBodies() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await ProfilesAPI(api: api).create(["name": "new", "clone_from": "default"])
        XCTAssertEqual(transport.lastPath, "/api/profile/create")
        assertJSONEqual(transport.lastBody(), ["name": "new", "clone_from": "default"])

        transport.enqueue(json: ["ok": true])
        try await ProfilesAPI(api: api).delete("new")
        XCTAssertEqual(transport.lastPath, "/api/profile/delete")
        assertJSONEqual(transport.lastBody(), ["name": "new"])
    }

    func testActivePersonalityReadsThePromptField() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["prompt": "You are JARVIS."])
        let prompt = try await ProfilesAPI(api: api).activePersonality()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/personality/active")
        XCTAssertEqual(prompt, "You are JARVIS.")

        transport.enqueue(json: JSONObject())
        let empty = try await ProfilesAPI(api: api).activePersonality()
        XCTAssertEqual(empty, "")
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsAndDerivesFlags() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profiles", json: [
            "profiles": [["name": "default"], ["name": "coder"]],
            "active": "coder",
        ])

        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.active, "coder")
        XCTAssertTrue(store.isActive(store.profiles[1]))
        XCTAssertFalse(store.canDelete(store.profiles[0]), "default is undeletable")
        XCTAssertFalse(store.canDelete(store.profiles[1]), "active is undeletable")
        XCTAssertEqual(store.cloneCandidates, ["default", "coder"])
    }

    @MainActor
    func testStoreSwitchConfirmsAgainstTheServersAnswer() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profile/switch", json: ["active": "coder"])
        transport.route("/api/profiles", json: ["profiles": [["name": "coder"]],
                                                "active": "coder"])

        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.switchTo("coder")
        XCTAssertEqual(store.toast, "Switched to \"coder\".")
    }

    @MainActor
    func testStoreSwitchSaysSoWhenTheServerDoesNotConfirm() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profile/switch", json: ["active": "default"])
        transport.route("/api/profiles", json: ["profiles": [["name": "default"]],
                                                "active": "default"])

        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.switchTo("coder")
        XCTAssertEqual(store.toast, "Switch to \"coder\" may not have applied.")
    }

    @MainActor
    func testStoreCreateRequiresANameAndDropsBlankOptionals() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profile/create", json: ["ok": true])
        transport.route("/api/profiles", json: ["profiles": [], "active": ""])

        let store = ProfilesStore(api: ProfilesAPI(api: api))

        let blank = await store.create(name: "  ", cloneFrom: nil, baseURL: "", apiKey: "",
                                       defaultModel: "", modelProvider: "")
        XCTAssertFalse(blank)
        XCTAssertEqual(store.toast, "Name is required.")
        XCTAssertTrue(transport.requests.isEmpty)

        let ok = await store.create(name: " coder ", cloneFrom: "default", baseURL: " ",
                                    apiKey: "sk-1", defaultModel: "", modelProvider: "anthropic")
        XCTAssertTrue(ok)
        assertJSONEqual(transport.body(0), [
            "name": "coder", "clone_from": "default", "clone_config": true,
            "api_key": "sk-1", "model_provider": "anthropic",
        ])
    }

    @MainActor
    func testStoreDeleteToasts() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/profile/delete", json: ["ok": true])
        transport.route("/api/profiles", json: ["profiles": [], "active": ""])

        let store = ProfilesStore(api: ProfilesAPI(api: api))
        await store.delete("old")
        XCTAssertEqual(store.toast, "Deleted \"old\".")
        XCTAssertEqual(transport.path(0), "/api/profile/delete")
    }
}
