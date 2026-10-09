import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Car page's Toyota side: what the server sends, what the phone sends back, and the store.
@MainActor
final class ToyotaTests: XCTestCase {
    static let car: [String: Any] = [
        "vin_last4": "0123", "range_mi": 353, "fuel_pct": 62.0, "odometer_mi": 63,
        "updated_at": "2026-10-08T20:41:00+00:00", "running": false,
        "commands": ["start", "stop", "lock", "unlock", "trunk_lock", "trunk_unlock", "lights", "horn",
                     "buzzer", "hazards_on", "hazards_off", "teleport"],
        "climate": ["custom": true, "temp": 68.0, "unit": "°F", "min": 60.0, "max": 85.0, "step": 1.0,
                    "defrost_front": false, "defrost_rear": false],
        "tires": ["fl": 36, "fr": 36, "rl": 35, "rr": 36, "unit": "psi",
                  "updated_at": "2026-10-08T20:30:00.123+00:00", "warnings": []],
        "doors": ["open": [], "locked": true], "windows": ["open": [], "locked": NSNull()],
        "trunk": ["open": [], "locked": true], "hood": NSNull(), "moonroof": NSNull(),
        "health": [["id": "tires", "title": "Tire pressure", "ok": true, "detail": "Good"]],
        "location": ["lat": 37.3349, "lon": -122.009, "at": "2026-10-08T18:00:00+00:00", "source": "parked"],
    ]
    static let signedIn: [String: Any] = ["account": ["state": "signed_in", "email": "p@example.com"], "car": car]

    private func store() -> (ToyotaStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        return (ToyotaStore(api: ToyotaAPI(api: api)), transport)
    }

    private func path(_ request: URLRequest?) -> String { request?.url?.path ?? "" }

    func testParsesTheCarLikeHisToyotaApp() {
        let car = ToyotaCar(json: Self.car)
        XCTAssertEqual(car.rangeMi, 353)
        XCTAssertEqual(car.odometerMi, 63)
        XCTAssertEqual(car.tires?.rl, 35)
        XCTAssertNotNil(car.tires?.updatedAt, "fractional-second timestamps parse")
        XCTAssertEqual(car.doors, .init(open: [], locked: true))
        XCTAssertNil(car.windows?.locked)
        XCTAssertNil(car.hood)
        XCTAssertEqual(car.climate?.temp, 68)
        XCTAssertEqual(car.commands.count, 11, "unknown commands are dropped")
        XCTAssertEqual(car.location?.lat, 37.3349)
    }

    func testAccountStates() {
        XCTAssertEqual(ToyotaAccount(json: ["state": "reauth"]).state, .reauth)
        XCTAssertTrue(ToyotaAccount(json: ["state": "reauth"]).needsSignIn)
        XCTAssertEqual(ToyotaAccount(json: ["state": "something new"]).state, .unavailable)
        XCTAssertNil(ToyotaAccount(state: .signedIn).blockedReason)
        XCTAssertEqual(ToyotaAccount(json: ["state": "ha_unreachable", "reason": "HA down"]).blockedReason, "HA down")
    }

    func testAHoldSendsTheCommandAsConfirmedThenReloads() async {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(json: ["ok": true, "command": "unlock", "result": "Unlocked"])
        transport.enqueue(json: Self.signedIn)
        await store.run(.unlock)
        let sent = transport.requests[1]
        XCTAssertEqual(path(sent), "/api/car/command")
        let body = (try? JSONSerialization.jsonObject(with: sent.httpBody ?? Data())) as? [String: Any]
        XCTAssertEqual(body?["command"] as? String, "unlock")
        XCTAssertEqual(body?["confirmed"] as? Bool, true)
        XCTAssertEqual(sent.timeoutInterval, ToyotaAPI.commandTimeout)
        XCTAssertLessThan(ToyotaAPI.commandTimeout, 100, "under Cloudflare's 100 s cut-off")
        XCTAssertEqual(store.outcome, .init(command: .unlock, text: "Unlocked", ok: true))
        XCTAssertNil(store.busy)
    }

    func testASlowAnswerIsPendingNotFailedAndTheButtonKeepsIt() async {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(error: URLError(.timedOut))
        transport.enqueue(json: ["account": ["state": "signed_in"], "car": Self.car.merging(["running": true]) { $1 }])
        await store.run(.start)
        XCTAssertEqual(store.outcome?.pending, true)
        XCTAssertNotNil(store.outcome(for: .stop), "Start flipped to Stop; the result stays on that button")
        XCTAssertNil(store.busy)
    }

    func testAnOkFalseReplyIsNotShownAsDone() async {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(json: ["ok": false, "needs_confirmation": true, "ask": "Unlock the car?"])
        await store.run(.unlock)
        XCTAssertEqual(store.outcome?.ok, false)
    }

    func testAFailedWakeStillShows() async {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(json: ["ok": false, "error": "Toyota didn't answer"], status: 502)
        transport.enqueue(json: Self.signedIn)
        await store.refresh()
        XCTAssertEqual(store.problem, "Toyota didn't answer")
    }

    func testHugeReadingsAreDroppedNotCrashed() {
        XCTAssertNil(ToyotaCar(json: ["odometer_mi": 1e20]).odometerMi)
    }

    func testNothingRunsWhileSignedOut() async {
        let (store, transport) = store()
        transport.enqueue(json: ["account": ["state": "signed_out"], "car": NSNull()])
        await store.load()
        await store.run(.horn)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testHazardsFlipToOffForFifteenMinutes() async {
        var now = Date(timeIntervalSince1970: 0)
        let (api, transport) = JarvisAPI.mocked()
        let store = ToyotaStore(api: ToyotaAPI(api: api), now: { now })
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(json: ["ok": true, "result": "Hazards on"])
        transport.enqueue(json: Self.signedIn)
        await store.run(.hazardsOn)
        XCTAssertTrue(store.hazardsOn)
        now = now.addingTimeInterval(ToyotaStore.hazardsMemory + 1)
        XCTAssertFalse(store.hazardsOn)
    }

    func testSignedOutByToyotaMidCommandShowsTheAccountAgain() async {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        transport.enqueue(json: ["ok": false, "error": "Toyota signed Jarvis out. Sign in again on the Car page."], status: 409)
        transport.enqueue(json: ["account": ["state": "reauth", "email": "p@example.com"], "car": NSNull()])
        await store.run(.lock)
        XCTAssertEqual(store.outcome?.ok, false)
        XCTAssertEqual(store.account?.state, .reauth)
    }

    func testSignInThenCodeThenSignedIn() async throws {
        let (store, transport) = store()
        transport.enqueue(json: ["ok": true, "step": "code", "flow_id": "f1"])
        let first = try await store.signIn(email: "p@example.com", password: "pw")
        XCTAssertEqual(first, .code(flowID: "f1"))
        XCTAssertEqual(transport.lastBody()["password"] as? String, "pw")
        transport.enqueue(json: ["ok": false, "error": "That code didn't work."], status: 400)
        do {
            _ = try await store.submitCode(flowID: "f1", code: "0")
            XCTFail("a wrong code throws")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That code didn't work.")
        }
        transport.enqueue(json: ["ok": true, "step": "done"])
        transport.enqueue(json: Self.signedIn)
        let second = try await store.submitCode(flowID: "f1", code: "123456")
        XCTAssertEqual(second, .done)
        XCTAssertEqual(transport.requests[2].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["flow_id"] as? String, "f1")
        XCTAssertTrue(store.isSignedIn)
    }

    func testSavingClimateSendsTheDraft() async throws {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        var draft = try XCTUnwrap(store.car?.climate)
        draft.temp = 72
        draft.defrostFront = true
        transport.enqueue(json: ["ok": true, "climate": ["custom": true, "temp": 72.0, "unit": "°F", "min": 60.0,
                                                          "max": 85.0, "step": 1.0, "defrost_front": true, "defrost_rear": false]])
        try await store.saveClimate(draft)
        XCTAssertEqual(transport.lastBody()["temp"] as? Double, 72)
        XCTAssertEqual(transport.lastBody()["defrost_front"] as? Bool, true)
        XCTAssertEqual(store.car?.climate?.temp, 72)
    }

    /// Renders each tab on the app's black; with `JC_RENDER_DIR` set the PNGs are written out.
    func testTabsRender() async throws {
        let (store, transport) = store()
        transport.enqueue(json: Self.signedIn)
        await store.load()
        let stage = CarStage()
        let views: [(String, AnyView)] = [
            ("toyota-controls", AnyView(CarControlsScreen(store: store, stage: stage).frame(height: 874))),
            ("toyota-status", AnyView(CarStatusScreen(store: store, stage: stage).frame(height: 874))),
            ("toyota-climate", AnyView(CarClimateScreen(store: store, stage: stage).frame(height: 780))),
            ("toyota-health", AnyView(CarHealthScreen(car: store.car))),
            ("toyota-account", AnyView(ToyotaAccountCard(store: store) {})),
        ]
        for (name, view) in views {
            let renderer = ImageRenderer(content: view.frame(width: 402).padding(.vertical, 20)
                .background(JcTheme.bg).environment(\.colorScheme, .dark))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage, name)
            XCTAssertGreaterThan(image.size.height, 100, name)
            if let dir = ProcessInfo.processInfo.environment["JC_RENDER_DIR"], let png = image.pngData() {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}
