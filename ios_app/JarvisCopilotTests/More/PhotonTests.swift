import Foundation
import XCTest
@testable import JarvisCopilot

/// No Dart test existed for `api/photon.dart`; these cover the write-only secret
/// contract and the status-pill precedence from `photon_setup_page.dart`.
final class PhotonTests: XCTestCase {

    // MARK: Models

    func testConfigParsesTheFullPayload() {
        let config = PhotonConfig(json: [
            "configured": true,
            "project_id": "proj_1",
            "project_secret_set": true,
            "notify_target": "+15551234567",
            "sidecar_url": "http://127.0.0.1:8787",
            "sidecar_token_set": false,
            "allowed_users": "a,b",
            "allow_all": true,
            "fields": [
                ["key": "project_id", "label": "Project ID", "required": true],
                ["key": "project_secret", "label": "Secret", "kind": "password"],
                ["key": "allow_all", "label": "Allow all", "kind": "bool"],
            ],
            "sidecar": ["reachable": true, "ok": true, "mock": false, "connected": true],
        ])
        XCTAssertTrue(config.configured)
        XCTAssertEqual(config.projectID, "proj_1")
        XCTAssertTrue(config.projectSecretSet)
        XCTAssertFalse(config.sidecarTokenSet)
        XCTAssertTrue(config.allowAll)
        XCTAssertEqual(config.fields.map(\.key),
                       ["project_id", "project_secret", "allow_all"])
        XCTAssertTrue(config.fields[0].required)
        // `kind: password` implies secret even without the legacy flag.
        XCTAssertTrue(config.fields[1].secret)
        XCTAssertFalse(config.fields[2].secret)
        XCTAssertEqual(config.fields[0].kind, "text")
        XCTAssertTrue(config.sidecar.ok)
    }

    func testConfigDefaultsWhenTheBodyIsEmpty() {
        let config = PhotonConfig(json: [:])
        XCTAssertFalse(config.configured)
        XCTAssertEqual(config.projectID, "")
        XCTAssertFalse(config.projectSecretSet)
        XCTAssertTrue(config.fields.isEmpty)
        XCTAssertFalse(config.sidecar.reachable)
        XCTAssertEqual(config.sidecar.error, "")
    }

    // MARK: Status precedence

    func testStatusPrecedence() {
        // Unconfigured wins even when the sidecar happens to be up.
        var sidecar = PhotonSidecar(json: ["reachable": true, "ok": true])
        XCTAssertEqual(PhotonStatus.resolve(configured: false, sidecar: sidecar).label,
                       "Not configured")
        XCTAssertEqual(PhotonStatus.resolve(configured: false, sidecar: sidecar).tone, .muted)

        sidecar = PhotonSidecar(json: [:])
        var status = PhotonStatus.resolve(configured: true, sidecar: sidecar)
        XCTAssertEqual(status.label, "Sidecar not reachable — is it running?")
        XCTAssertEqual(status.tone, .amber)

        sidecar = PhotonSidecar(json: ["reachable": true, "ok": true, "mock": true])
        status = PhotonStatus.resolve(configured: true, sidecar: sidecar)
        XCTAssertEqual(status.label, "Sidecar in mock mode — tap Save to reload")
        XCTAssertEqual(status.tone, .amber)

        sidecar = PhotonSidecar(json: ["reachable": true, "ok": true])
        status = PhotonStatus.resolve(configured: true, sidecar: sidecar)
        XCTAssertEqual(status.label, "Connected — iMessage live")
        XCTAssertEqual(status.tone, .success)

        sidecar = PhotonSidecar(json: ["reachable": true, "error": "handshake failed"])
        status = PhotonStatus.resolve(configured: true, sidecar: sidecar)
        XCTAssertEqual(status.label, "Sidecar error: handshake failed")
        XCTAssertEqual(status.tone, .danger)

        sidecar = PhotonSidecar(json: ["reachable": true])
        XCTAssertEqual(PhotonStatus.resolve(configured: true, sidecar: sidecar).label,
                       "Sidecar error")
    }

    // MARK: API requests

    func testGetConfigPath() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["configured": true, "project_id": "p"])
        let config = try await PhotonAPI(api: api).config()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/integrations/photon")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(config.projectID, "p")
    }

    func testSaveAlwaysSendsAllowAllAndOmitsUnsuppliedKeys() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["configured": true])
        _ = try await PhotonAPI(api: api).save(allowAll: true)

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/integrations/photon")
        assertJSONEqual(transport.lastBody(), ["allow_all": true])
    }

    func testSaveIncludesEverySuppliedField() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["configured": true, "allow_all": false])
        let config = try await PhotonAPI(api: api).save(
            projectID: "p", projectSecret: "s", notifyTarget: "+1",
            sidecarURL: "http://x", sidecarToken: "t", allowedUsers: "a",
            allowAll: false)

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/integrations/photon")
        assertJSONEqual(transport.lastBody(), [
            "project_id": "p", "project_secret": "s", "notify_target": "+1",
            "sidecar_url": "http://x", "sidecar_token": "t",
            "allowed_users": "a", "allow_all": false,
        ])
        // The reply is the new config — the screen renders THIS, not the values
        // it just sent, so discarding it would hide a server that said no.
        XCTAssertTrue(config.configured)
        XCTAssertFalse(config.allowAll)
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsIntoTheFormFields() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: [
            "configured": true, "project_id": "proj", "project_secret_set": true,
            "notify_target": "+1", "sidecar_url": "http://127.0.0.1:8787",
            "allowed_users": "a,b", "allow_all": true,
            "sidecar": ["reachable": true, "ok": true],
        ])

        let store = PhotonStore(api: PhotonAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.projectID, "proj")
        XCTAssertEqual(store.notifyTarget, "+1")
        XCTAssertEqual(store.sidecarURL, "http://127.0.0.1:8787")
        XCTAssertEqual(store.allowedUsers, "a,b")
        XCTAssertTrue(store.allowAll)
        XCTAssertEqual(store.projectSecretHint, "saved — leave blank to keep")
        XCTAssertNil(store.sidecarTokenHint)
        XCTAssertEqual(store.status.label, "Connected — iMessage live")
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testStoreSaveRequiresAProjectID() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = PhotonStore(api: PhotonAPI(api: api))
        let ok = await store.save()
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, "Project ID is required")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreSaveRequiresASecretUntilOneIsStored() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = PhotonStore(api: PhotonAPI(api: api))
        store.projectID = "proj"
        let ok = await store.save()
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, "Project secret is required")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreBlankSecretPreservesTheStoredOne() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: [
            "configured": true, "project_id": "proj", "project_secret_set": true,
            "sidecar": ["reachable": true, "ok": true],
        ])

        let store = PhotonStore(api: PhotonAPI(api: api))
        await store.refresh()
        let ok = await store.save()

        XCTAssertTrue(ok)
        let body = transport.body(1)
        XCTAssertNil(body["project_secret"], "a blank secret must be omitted, not sent as \"\"")
        XCTAssertNil(body["sidecar_token"])
        XCTAssertEqual(body["project_id"] as? String, "proj")
        XCTAssertEqual(store.toast, "Photon connected — iMessage is set up.")
    }

    @MainActor
    func testStoreTypedSecretsAreSentThenClearedAndFlagged() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: [
            "configured": true, "sidecar": ["reachable": true, "ok": true, "mock": true],
        ])

        let store = PhotonStore(api: PhotonAPI(api: api))
        store.projectID = "proj"
        store.projectSecret = "shhh"
        store.sidecarToken = "tok"
        let ok = await store.save()

        XCTAssertTrue(ok)
        let body = transport.body(0)
        XCTAssertEqual(body["project_secret"] as? String, "shhh")
        XCTAssertEqual(body["sidecar_token"] as? String, "tok")
        XCTAssertEqual(store.projectSecret, "", "the input clears after a save")
        XCTAssertEqual(store.sidecarToken, "")
        XCTAssertEqual(store.projectSecretHint, "saved — leave blank to keep")
        XCTAssertEqual(store.sidecarTokenHint, "saved — leave blank to keep")
        // The POST reloads the gateway, so the pill updates without leaving.
        XCTAssertEqual(store.status.label, "Sidecar in mock mode — tap Save to reload")
    }

    @MainActor
    func testStoreSaveTrimsNonSecretFieldsButNotSecrets() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: ["configured": false])

        let store = PhotonStore(api: PhotonAPI(api: api))
        store.projectID = "  proj  "
        store.projectSecret = "  shhh  "
        store.notifyTarget = "  +1  "
        store.sidecarURL = "  http://x  "
        store.allowedUsers = "  a  "
        _ = await store.save()

        let body = transport.body(0)
        XCTAssertEqual(body["project_id"] as? String, "proj")
        XCTAssertEqual(body["notify_target"] as? String, "+1")
        XCTAssertEqual(body["sidecar_url"] as? String, "http://x")
        XCTAssertEqual(body["allowed_users"] as? String, "a")
        XCTAssertEqual(body["project_secret"] as? String, "  shhh  ",
                       "secrets go over the wire verbatim")
        XCTAssertEqual(store.toast, "Saved.")
    }

    @MainActor
    func testStoreSaveSurfacesAnHTTP400() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: ["error": "bad project id"], status: 400)

        let store = PhotonStore(api: PhotonAPI(api: api))
        store.projectID = "proj"
        store.projectSecret = "s"
        let ok = await store.save()

        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, "bad project id")
    }

    @MainActor
    func testSecretPlaceholder() {
        XCTAssertEqual(PhotonStore.secretPlaceholder, "••••••••")
    }
}
