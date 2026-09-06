import XCTest
@testable import JarvisCopilot

@MainActor
final class CodeMasterSettingsStoreTests: XCTestCase {

    private func makeStore() -> (CodeMasterSettingsStore, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        return (CodeMasterSettingsStore(api: CodingSessionsAPI(api: client)), transport)
    }

    func testTheDefaultMatrixMatchesTheBackend() {
        let (store, _) = makeStore()
        XCTAssertEqual(CodeMasterSettingsStore.events.map(\.key), ["finished", "needs_input", "error"])
        XCTAssertEqual(CodeMasterSettingsStore.channels.map(\.key),
                       ["telegram", "mobile", "toast", "photon"])
        for event in CodeMasterSettingsStore.events.map(\.key) {
            XCTAssertFalse(store.value(event: event, channel: "telegram"))
            XCTAssertTrue(store.value(event: event, channel: "mobile"))
            XCTAssertTrue(store.value(event: event, channel: "toast"))
            XCTAssertFalse(store.value(event: event, channel: "photon"))
        }
        XCTAssertTrue(store.usageDisplay)
        XCTAssertFalse(store.remoteApprovals)
    }

    /// The matrix a fresh store starts from, and the one `load()` overlays onto —
    /// every event×channel cell must exist, or a server that omits a key would
    /// leave a hole the UI reads as "off".
    func testDefaultMatrixIsFullyPopulated() {
        let matrix = CodeMasterSettingsStore.defaultMatrix()
        XCTAssertEqual(Set(matrix.keys), ["finished", "needs_input", "error"])
        for (event, row) in matrix {
            XCTAssertEqual(Set(row.keys), ["telegram", "mobile", "toast", "photon"],
                           "\(event) is missing a channel")
            XCTAssertEqual(row, ["telegram": false, "mobile": true,
                                 "toast": true, "photon": false])
        }
        // Every cell matches the backend's own per-channel default…
        for (_, row) in matrix {
            for (channel, on) in row {
                XCTAssertEqual(on, CodeMasterSettingsStore.channelDefaults[channel])
            }
        }
        // …and the store is initialised from exactly this.
        let (store, _) = makeStore()
        XCTAssertEqual(store.events, matrix)
    }

    func testLoadMergesOverTheDefaults() async {
        let (store, t) = makeStore()
        // The server only reports a couple of cells — the rest must keep their
        // defaults, not silently switch off.
        t.enqueue(json: ["settings": [
            "events": ["finished": ["telegram": true, "toast": false],
                       "error": ["photon": true]],
            "remote_approvals": true,
        ]])
        await store.load()
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.value(event: "finished", channel: "telegram"))
        XCTAssertFalse(store.value(event: "finished", channel: "toast"))
        XCTAssertTrue(store.value(event: "finished", channel: "mobile"), "default kept")
        XCTAssertTrue(store.value(event: "error", channel: "photon"))
        XCTAssertTrue(store.value(event: "needs_input", channel: "toast"), "whole row defaulted")
        XCTAssertTrue(store.usageDisplay, "absent ⇒ stays on")
        XCTAssertTrue(store.remoteApprovals)
    }

    func testUsageDisplayIsOnUnlessTheServerSaysFalse() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["settings": ["usage_display": false]])
        await store.load()
        XCTAssertFalse(store.usageDisplay)

        let (other, t2) = makeStore()
        // A non-bool must not flip it (the Dart code compared against `false`).
        t2.enqueue(json: ["settings": ["usage_display": 0, "remote_approvals": 1]])
        await other.load()
        XCTAssertTrue(other.usageDisplay)
        XCTAssertFalse(other.remoteApprovals)
    }

    func testAMalformedBodyLeavesTheDefaults() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["ok": true])
        await store.load()
        XCTAssertTrue(store.usageDisplay)
        XCTAssertTrue(store.value(event: "finished", channel: "mobile"))
        XCTAssertNil(store.error)
    }

    func testLoadFailureSurfacesTheServerMessage() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["error": "settings store offline"], status: 500)
        await store.load()
        XCTAssertEqual(store.error, "settings store offline")
        XCTAssertFalse(store.loading)
    }

    func testEditingTheMatrix() {
        let (store, _) = makeStore()
        store.set(event: "finished", channel: "telegram", true)
        XCTAssertTrue(store.value(event: "finished", channel: "telegram"))
        store.toggle(event: "finished", channel: "telegram")
        XCTAssertFalse(store.value(event: "finished", channel: "telegram"))
    }

    func testPayloadIsTheFullDocument() {
        let (store, _) = makeStore()
        store.set(event: "error", channel: "photon", true)
        store.usageDisplay = false
        store.remoteApprovals = true
        let payload = store.payload()
        XCTAssertEqual(payload["usage_display"] as? Bool, false)
        XCTAssertEqual(payload["remote_approvals"] as? Bool, true)
        let events = payload["events"] as? [String: Any] ?? [:]
        XCTAssertEqual(events.count, 3)
        for event in CodeMasterSettingsStore.events.map(\.key) {
            let row = events[event] as? [String: Any] ?? [:]
            XCTAssertEqual(row.count, 4, "every channel is written, default or not")
        }
        XCTAssertEqual((events["error"] as? [String: Any])?["photon"] as? Bool, true)
        XCTAssertEqual((events["finished"] as? [String: Any])?["mobile"] as? Bool, true)
    }

    func testSaveSendsThePayloadAndAdoptsTheServersCopy() async {
        let (store, t) = makeStore()
        store.remoteApprovals = true
        store.set(event: "finished", channel: "telegram", true)
        t.enqueue(json: ["ok": true, "settings": [
            "events": ["finished": ["telegram": false]],
            "remote_approvals": false,
        ]])
        let value1 = await store.save()
        XCTAssertTrue(value1)
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/coding/settings")
        XCTAssertEqual(t.lastRequest?.httpMethod, "POST")
        let sent = t.lastBody()
        XCTAssertEqual(sent["remote_approvals"] as? Bool, true, "we sent our state…")
        // …and then adopted the server's canonical answer.
        XCTAssertFalse(store.value(event: "finished", channel: "telegram"))
        XCTAssertFalse(store.remoteApprovals)
        XCTAssertNotNil(store.savedAt)
        XCTAssertFalse(store.saving)
    }

    func testSaveKeepsLocalStateForKeysTheServerOmits() async {
        let (store, t) = makeStore()
        store.usageDisplay = false
        store.remoteApprovals = true
        store.set(event: "error", channel: "photon", true)
        t.enqueue(json: ["ok": true, "settings": ["events": [String: Any]()]])
        let value2 = await store.save()
        XCTAssertTrue(value2)
        XCTAssertFalse(store.usageDisplay, "no usage_display in the reply ⇒ keep ours")
        XCTAssertTrue(store.remoteApprovals)
        XCTAssertTrue(store.value(event: "error", channel: "photon"))
    }

    func testSaveFailure() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["error": "read-only config"], status: 403)
        let value3 = await store.save()
        XCTAssertFalse(value3)
        XCTAssertEqual(store.error, "read-only config")
        XCTAssertNil(store.savedAt)
        XCTAssertFalse(store.saving)
    }
}
