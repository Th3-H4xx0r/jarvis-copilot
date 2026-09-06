import Foundation
import XCTest
@testable import JarvisCopilot

/// No Dart test existed for `api/devices.dart`; these cover the endpoints and
/// the `devices_page.dart` logic (list, revoke, logout, the skills ACL, and the
/// health/wiki strip).
final class DevicesTests: XCTestCase {

    // MARK: Models

    func testDeviceParsesAliasesAndDerivesDisplayFields() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let device = Device(json: [
            "id": "d1", "label": "Pranav's iPhone", "platform": "ios",
            "online": true, "last_seen": now.timeIntervalSince1970 - 120,
            "created_at": "2026-06-01T10:00:00Z",
            "skills": [["name": "notify", "title": "Notify"]],
        ])
        XCTAssertEqual(device.id, "d1")
        XCTAssertEqual(device.displayName, "Pranav's iPhone")
        XCTAssertTrue(device.online)
        XCTAssertEqual(device.statusLabel, "ONLINE")
        XCTAssertEqual(device.statusTone, .success)
        XCTAssertEqual(device.lastSeenLabel(now: now), "2m ago")
        XCTAssertEqual(device.skills.map(\.displayName), ["Notify"])
    }

    func testDeviceFallsBackToIDThenAPlaceholderForItsName() {
        XCTAssertEqual(Device(json: ["device_id": "abc"]).displayName, "abc")
        XCTAssertEqual(Device(json: [:]).displayName, "(unknown device)")
        XCTAssertEqual(Device(json: [:]).statusLabel, "OFFLINE")
        XCTAssertEqual(Device(json: [:]).statusTone, .muted)
    }

    func testSkillIsAllowedUnlessExplicitlyDenied() {
        XCTAssertTrue(DeviceSkill(json: ["name": "a"]).allowed)
        XCTAssertTrue(DeviceSkill(json: ["name": "a", "allowed": true]).allowed)
        XCTAssertFalse(DeviceSkill(json: ["name": "a", "allowed": false]).allowed)
        XCTAssertEqual(DeviceSkill(json: ["skill": "b"]).name, "b")
        XCTAssertEqual(DeviceSkill(json: ["name": "b"]).displayName, "b")
    }

    // MARK: API requests

    func testListReadsTheDevicesEnvelope() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["devices": [["id": "d1"], ["id": "d2"]]])
        let devices = try await DevicesAPI(api: api).list()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/devices")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(devices.map(\.id), ["d1", "d2"])
    }

    func testAllSkillsReadsTheSkillsEnvelope() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["skills": [["name": "notify"], ["name": "run_code"]]])
        let skills = try await DevicesAPI(api: api).allSkills()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/devices/skills")
        XCTAssertEqual(skills.map(\.name), ["notify", "run_code"])
    }

    func testRevokeDeletesTheDeviceByID() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await DevicesAPI(api: api).revoke("d1")

        XCTAssertEqual(transport.lastMethod, "DELETE")
        XCTAssertEqual(transport.lastPath, "/api/devices/d1")
        XCTAssertNil(transport.lastRequest?.httpBody)
    }

    func testLogoutPostsAnEmptyBody() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await DevicesAPI(api: api).logout("d1")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/devices/d1/logout")
        XCTAssertTrue(transport.lastBody().isEmpty)
    }

    func testStartPairSendsTTLAndOptionalLabel() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["code": "123456", "expires_in": 600])
        _ = try await DevicesAPI(api: api).startPair()
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/devices/pair/start")
        assertJSONEqual(transport.lastBody(), ["ttl": 600])

        transport.enqueue(json: ["code": "654321"])
        _ = try await DevicesAPI(api: api).startPair(ttl: 120, label: "Watch")
        assertJSONEqual(transport.lastBody(), ["ttl": 120, "label": "Watch"])
    }

    func testInvokeSendsDeviceSkillArgsAndTimeout() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "result": "done"])
        _ = try await DevicesAPI(api: api).invoke(deviceID: "d1", skill: "notify",
                                                  args: ["title": "hi"], timeout: 5)

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/devices/skills/invoke")
        assertJSONEqual(transport.lastBody(), [
            "device_id": "d1", "skill": "notify",
            "args": ["title": "hi"], "timeout": 5,
        ])
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsDevicesCatalogueAndTheHealthStrip() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["skills": [
            ["name": "notify"], ["name": "run_code"], ["name": "camera"],
        ]])
        transport.route("/api/devices", json: ["devices": [
            ["id": "d1", "label": "Phone", "online": true,
             "skills": [["name": "notify"], ["name": "camera", "allowed": false]]],
        ]])
        transport.route("/api/system/health", json: ["available": true, "cpu": ["percent": 12]])
        transport.route("/api/wiki/status", json: ["available": true, "entry_count": 3])

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.devices.map(\.id), ["d1"])
        XCTAssertEqual(store.health.cpuPercent, 12)
        XCTAssertEqual(store.wiki.entryCount, 3)

        // The ACL is expressed against the whole catalogue.
        let acl = store.skills(for: store.devices[0])
        XCTAssertEqual(acl.count, 3)
        XCTAssertEqual(Set(acl.filter(\.allowed).map(\.name)), ["notify"])
        XCTAssertEqual(store.grantedSkills(for: store.devices[0]).map(\.name), ["notify"])
    }

    @MainActor
    func testStoreFallsBackToTheDevicesOwnSkillsWithoutACatalogue() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["error": "off"], status: 500)
        transport.route("/api/devices", json: ["devices": [
            ["id": "d1", "skills": [["name": "notify"]]],
        ]])
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertTrue(store.catalogue.isEmpty)
        XCTAssertEqual(store.skills(for: store.devices[0]).map(\.name), ["notify"])
    }

    @MainActor
    func testStoreSurfacesAListFailure() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["skills": []])
        transport.route("/api/devices", json: ["error": "not paired"], status: 401)
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.errorMessage, "not paired")
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.emptyText, "No devices found")
    }

    @MainActor
    func testStoreRevokeAndLogoutRefreshAfterwards() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/d1/logout", json: ["ok": true])
        transport.route("/api/devices/skills", json: ["skills": []])
        transport.route("/api/devices/d1", json: ["ok": true])
        transport.route("/api/devices", json: ["devices": []])
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        let device = Device(json: ["id": "d1"])

        await store.logout(device)
        XCTAssertEqual(transport.path(0), "/api/devices/d1/logout")
        XCTAssertTrue(transport.paths.contains("/api/devices"), "the list reloads")

        let before = transport.requests.count
        await store.revoke(device)
        XCTAssertEqual(transport.method(before), "DELETE")
        XCTAssertEqual(transport.path(before), "/api/devices/d1")
    }

    @MainActor
    func testStoreMutationFailurePrefixesTheMessage() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/d1/logout", json: ["error": "gone"], status: 404)

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.logout(Device(json: ["id": "d1"]))
        XCTAssertEqual(store.toast, "Failed: gone")
    }

    @MainActor
    func testStoreStartPairReturnsTheCode() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/pair/start", json: ["code": "123456"])

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        let reply = await store.startPair(ttl: 300, label: "Watch") ?? [:]
        XCTAssertEqual(MoreJSON.text(reply["code"]), "123456")
        assertJSONEqual(transport.body(0), ["ttl": 300, "label": "Watch"])
    }
}
