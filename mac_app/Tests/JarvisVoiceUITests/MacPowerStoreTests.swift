import XCTest
@testable import JarvisVoiceUI

@MainActor
final class MacPowerStoreTests: XCTestCase {
    func testRowsDecodeAndSubtitles() {
        let store = MacPowerStore()
        store.apply(["integrations": [
            ["id": "kanban", "name": "Kanban", "enabled": true, "status_line": "1 running"],
            ["id": "vault", "name": "Vault", "enabled": false, "protected": true,
             "settings_schema": [["key": "k", "label": "K", "kind": "secret"]], "settings": ["k": ["set": true]]],
            ["name": "no id"],
        ]])
        XCTAssertEqual(store.rows.map(\.id), ["kanban", "vault"])
        XCTAssertEqual(store.subtitle(store.rows[0]), "1 running")
        XCTAssertEqual(store.subtitle(store.rows[1]), "Off")
        XCTAssertEqual(store.rows[1].settings["k"], .secretSet(true))
    }
}
