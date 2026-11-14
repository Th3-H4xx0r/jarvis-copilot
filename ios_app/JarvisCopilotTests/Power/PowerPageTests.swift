import XCTest
@testable import JarvisCopilot

@MainActor
final class PowerPageTests: XCTestCase {
    private func row(enabled: Bool = true, status: String = "Armed (home)",
                     links: [[String: Any]] = []) -> PowerRow {
        PowerRow(json: ["id": "door-alarm", "name": "Door alarm", "enabled": enabled,
                        "summary": "Your door sensors as an alarm.", "status_line": status,
                        "protected": true, "links": links,
                        "settings_schema": [["key": "token", "label": "Token", "kind": "secret"]],
                        "settings": ["token": ["set": true]]])!
    }

    func testSubtitleSaysWaitingThenOffThenStatus() {
        XCTAssertEqual(PowerCopy.subtitle(row(), pending: true), "Waiting for Face ID")
        XCTAssertEqual(PowerCopy.subtitle(row(enabled: false), pending: false), "Off")
        XCTAssertEqual(PowerCopy.subtitle(row(), pending: false), "Armed (home)")
        XCTAssertEqual(PowerCopy.subtitle(row(status: ""), pending: false), "Your door sensors as an alarm.")
    }

    func testSecretNeverDisplayed() {
        let r = row()
        XCTAssertEqual(r.settings["token"], .secretSet(true))
        XCTAssertEqual(PowerSettingsForm.secretLabel(r.settings["token"]!), "Set")
        XCTAssertEqual(PowerSettingsForm.secretLabel(.secretSet(false)), "Not set")
    }

    func testLinksOnlyForIOSPlatform() {
        let r = row(links: [["platform": "ios", "target": "door_page", "label": "Open"],
                            ["platform": "web", "target": "door", "label": "Open"]])
        XCTAssertEqual(r.iosLinks.map(\.target), ["door_page"])
    }

    func testPowerUIStoresUseTheirOwnEndpointAndCache() {
        let regular = IntegrationUIStore(integrationID: "jarvis-health", presentation: .card)
        let power = IntegrationUIStore(integrationID: "jarvis-health", presentation: .card,
                                       basePath: PowerAPI.prefix)
        XCTAssertEqual(regular.basePath, "/api/integrations")
        XCTAssertEqual(power.basePath, "/api/power")
    }

    func testMalformedRowsAreSkipped() {
        XCTAssertNil(PowerRow(json: ["name": "No id"]))
        XCTAssertNil(PowerSetting(json: ["key": "x", "kind": "weird"]))
    }
}
