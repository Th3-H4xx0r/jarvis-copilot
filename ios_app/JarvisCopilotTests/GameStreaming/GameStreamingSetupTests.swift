import XCTest
@testable import JarvisCopilot

/// The Game Streaming setup: the name->type guess table, the device-draft builder,
/// the detect headline, and that Save writes the login + the structured targets.
@MainActor
final class GameStreamingSetupTests: XCTestCase {

    // MARK: name -> type guess

    func testTypeGuessTable() {
        XCTAssertEqual(GameTypeGuess.kind(for: "MacBook Pro"), "mac")
        XCTAssertEqual(GameTypeGuess.kind(for: "Pranav's iMac"), "mac")
        XCTAssertEqual(GameTypeGuess.kind(for: "SHIELD Android TV"), "androidtv")
        XCTAssertEqual(GameTypeGuess.kind(for: "Fire TV Stick"), "androidtv")
        XCTAssertEqual(GameTypeGuess.kind(for: "Google TV"), "androidtv")
        XCTAssertEqual(GameTypeGuess.kind(for: "Living Room TV"), "androidtv")
        XCTAssertEqual(GameTypeGuess.kind(for: "iPhone 17 Pro"), "ios")
        XCTAssertEqual(GameTypeGuess.kind(for: "Pranav's iPad"), "ios")
        XCTAssertEqual(GameTypeGuess.kind(for: "Steam Deck"), "mac")   // unknown -> editable mac
    }

    // MARK: drafts from paired + saved targets

    func testDraftsGuessUnknownAndKeepSavedTypeAndAddress() {
        let paired = [GamePaired(name: "MacBook", uuid: "u1"),
                      GamePaired(name: "Shield", uuid: "u2"),
                      GamePaired(name: "Spare Phone", uuid: "u3")]
        let targets = [GameTarget(name: "Shield", kind: "androidtv", host: "gpc", tvAddr: "10.0.0.5:5555"),
                       GameTarget(name: "Old TV", kind: "androidtv", host: "gpc", tvAddr: "10.0.0.9:5555")]
        let drafts = GameSetupModel.drafts(paired: paired, targets: targets)
        // paired first, then saved targets Sunshine no longer lists
        XCTAssertEqual(drafts.map(\.name), ["MacBook", "Shield", "Spare Phone", "Old TV"])
        XCTAssertEqual(drafts[0].kind, "mac")                 // guessed
        XCTAssertEqual(drafts[1].kind, "androidtv")           // from saved target
        XCTAssertEqual(drafts[1].tvAddr, "10.0.0.5:5555")     // adb address carried over
        XCTAssertEqual(drafts[2].kind, "mac")                 // "Spare Phone" has no iphone/ipad token -> mac
        XCTAssertEqual(drafts[3].name, "Old TV")              // saved-only target appended
    }

    // MARK: detect headline

    func testDetectHeadline() {
        XCTAssertEqual(GameDetect(online: true, running: true, needsLogin: false).headline,
                       "Found Sunshine on your gaming PC")
        XCTAssertTrue(GameDetect(online: true, running: true, needsLogin: false).found)
        XCTAssertEqual(GameDetect(online: true, running: true, needsLogin: true).headline,
                       "Sunshine is running — add your Sunshine login below")
        XCTAssertEqual(GameDetect(online: true, running: false).headline,
                       "Sunshine isn't running on your PC yet")
        XCTAssertEqual(GameDetect(online: false).headline,
                       "Your PC is offline — turn it on to finish setup")
    }

    func testDetectDecodesSnakeCase() {
        let d = GameDetect(json: ["online": true, "running": true, "needs_login": true])
        XCTAssertTrue(d.online && d.running && d.needsLogin)
    }

    // MARK: save writes login + structured targets (no JSON)

    private func sampleStatus() -> GameStreamingStatus {
        GameStreamingStatus(ok: true, reachable: true, live: GameLive(active: false),
                            paired: [GamePaired(name: "MacBook", uuid: "u1"),
                                     GamePaired(name: "Shield", uuid: "u2")],
                            apps: [], targets: [])
    }

    private func powerRow() -> PowerRow {
        PowerRow(json: [
            "id": "game-streaming", "name": "Game Streaming", "enabled": true,
            "settings_schema": [
                ["key": "user", "label": "Sunshine username", "kind": "text"],
                ["key": "password", "label": "Sunshine password", "kind": "secret"],
                ["key": "log_path", "label": "Sunshine log path", "kind": "text"],
            ],
            "settings": ["user": "", "password": ["set": false], "log_path": ""],
            "native": ["ios": ["settings"]],
        ])!
    }

    func testSaveWritesLoginAndTargets() async {
        let fake = FakeSetupAPI(status: sampleStatus())
        let captured = CapturedSends()
        let defaults = UserDefaults(suiteName: "gs-setup-\(UUID().uuidString)")!
        let row = powerRow()
        let power = PowerState(
            fetch: { ["integrations": [["id": "game-streaming", "name": "Game Streaming", "enabled": true]]] },
            send: { id, body in captured.record(id, body); return ["ok": true] },
            defaults: defaults, showApprovals: {})
        let store = GameStreamingSetupStore(client: fake)
        store.seed(from: row)
        await store.refresh()
        // Fix a type and enter a login + an Android TV address.
        store.user = "admin"
        store.password = "hunter2"
        store.setKind("androidtv", for: "Shield")
        store.setAddr("10.0.0.5:5555", for: "Shield")

        let result = await store.save(row: row, power: power)
        if case .ok = result {} else { XCTFail("expected ok, got \(result)") }

        // login saved through Power settings
        XCTAssertEqual(captured.sends.count, 1)
        let body = captured.sends.first?.body["settings"] as? [String: Any]
        XCTAssertEqual(body?["user"] as? String, "admin")
        XCTAssertEqual(body?["password"] as? String, "hunter2")

        // structured targets posted (no JSON): MacBook=mac, Shield=androidtv+addr
        let saved = Dictionary(uniqueKeysWithValues: fake.savedTargets.map { ($0.name, $0) })
        XCTAssertEqual(saved["MacBook"]?.kind, "mac")
        XCTAssertEqual(saved["Shield"]?.kind, "androidtv")
        XCTAssertEqual(saved["Shield"]?.tvAddr, "10.0.0.5:5555")
        XCTAssertEqual(saved["MacBook"]?.tvAddr, "")   // non-TV carries no address
    }

    func testSaveSkipsLoginWhenUnchanged() async {
        let fake = FakeSetupAPI(status: sampleStatus())
        let captured = CapturedSends()
        let defaults = UserDefaults(suiteName: "gs-setup-\(UUID().uuidString)")!
        let row = powerRow()
        let power = PowerState(
            fetch: { ["integrations": [["id": "game-streaming", "name": "Game Streaming", "enabled": true]]] },
            send: { id, body in captured.record(id, body); return ["ok": true] },
            defaults: defaults, showApprovals: {})
        let store = GameStreamingSetupStore(client: fake)
        store.seed(from: row)
        await store.refresh()
        _ = await store.save(row: row, power: power)
        // nothing changed in the login -> no settings write, but targets still saved
        XCTAssertTrue(captured.sends.isEmpty)
        XCTAssertEqual(fake.savedTargets.map(\.name).sorted(), ["MacBook", "Shield"])
    }
}

/// A setup-capable fake: records the targets it was asked to write.
final class FakeSetupAPI: GameStreamingAPI {
    var detectValue = GameDetect(online: true, running: true, needsLogin: false)
    var statusValue: GameStreamingStatus
    private(set) var savedTargets: [GameTargetEdit] = []

    init(status: GameStreamingStatus) { statusValue = status }

    func status() async throws -> GameStreamingStatus { statusValue }
    func start(target: String, game: String) async throws -> GameStartOutcome { .started(note: nil) }
    func stop(target: String?) async throws {}
    func pair(device: String, pin: String) async throws -> GamePairOutcome { .paired(detail: nil) }
    func unpair(device: String) async throws {}
    func detect() async throws -> GameDetect { detectValue }
    func setTargets(_ targets: [GameTargetEdit]) async throws { savedTargets = targets }
}

/// Captures the Power settings writes the setup store makes.
final class CapturedSends {
    var sends: [(id: String, body: [String: Any])] = []
    func record(_ id: String, _ body: [String: Any]) { sends.append((id, body)) }
}
