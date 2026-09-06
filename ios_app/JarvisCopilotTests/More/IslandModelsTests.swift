import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/island_models_test.dart`, case for case.
final class IslandModelsTests: XCTestCase {

    func testIslandDesignFromJSONAndJSONStringRoundTrip() throws {
        let raw: JSONObject = [
            "id": "deploy",
            "name": "Deploy status",
            "icon": "shippingbox.fill",
            "version": 7,
            "presentations": ["expanded": ["type": "text", "value": "hi"]],
        ]
        let design = IslandDesign(json: raw)
        XCTAssertEqual(design.id, "deploy")
        XCTAssertEqual(design.name, "Deploy status")
        XCTAssertEqual(design.version, 7)

        let decoded = try JSONSerialization.jsonObject(with: Data(design.jsonString.utf8))
        let presentations = (decoded as? JSONObject)?["presentations"] as? JSONObject
        let expanded = presentations?["expanded"] as? JSONObject
        XCTAssertEqual(expanded?["type"] as? String, "text")
    }

    func testCatalogEntryDefaultsEnabledTrueBuiltinFalse() {
        let entry = IslandCatalogEntry(json: ["id": "x", "priority": 5])
        XCTAssertTrue(entry.enabled)
        XCTAssertFalse(entry.builtin)
        XCTAssertEqual(entry.priority, 5)
        XCTAssertNil(entry.conditions)
    }

    func testCatalogEntryParsesBuiltinAndRules() {
        let entry = IslandCatalogEntry(json: [
            "id": "voice",
            "builtin": true,
            "enabled": false,
            "priority": 100,
            "conditions": ["op": "exists", "a": ["$": "x"]],
            "schedule": ["from": "09:00", "to": "17:00"],
        ])
        XCTAssertTrue(entry.isVoice)
        XCTAssertTrue(entry.builtin)
        XCTAssertFalse(entry.enabled)
        XCTAssertEqual(entry.conditions?["op"] as? String, "exists")
        XCTAssertEqual(entry.schedule?["from"] as? String, "09:00")
    }

    func testSelectionParsingAndDefaults() {
        XCTAssertTrue(IslandSelection(json: nil).isAuto)
        let pinned = IslandSelection(json: ["mode": "pinned", "pinnedId": "deploy"])
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.pinnedID, "deploy")
        // An unknown mode falls back to auto.
        XCTAssertTrue(IslandSelection(json: ["mode": "wat"]).isAuto)
    }

    func testCatalogFromJSONWiresDesignsCatalogSelectionAndData() {
        let catalog = IslandCatalog(json: [
            "designs": [[
                "id": "deploy", "name": "Deploy", "version": 2,
                "presentations": ["expanded": ["type": "divider"]],
            ]],
            "catalog": [
                ["id": "voice", "builtin": true, "priority": 100],
                ["id": "deploy", "priority": 10],
            ],
            "selection": ["mode": "pinned", "pinnedId": "deploy"],
            "data": ["deploy": ["pct": 62]],
        ])
        XCTAssertEqual(catalog.designs.count, 1)
        XCTAssertEqual(catalog.design(id: "deploy")?.version, 2)
        XCTAssertEqual(catalog.entry(id: "voice")?.builtin, true)
        XCTAssertEqual(catalog.selection.pinnedID, "deploy")
        XCTAssertEqual(MoreJSON.int(catalog.data(for: "deploy")["pct"]), 62)
        XCTAssertTrue(catalog.data(for: "missing").isEmpty)
    }

    func testCatalogEmptyIsSafe() {
        XCTAssertTrue(IslandCatalog.empty.designs.isEmpty)
        XCTAssertTrue(IslandCatalog.empty.selection.isAuto)
        XCTAssertTrue(IslandCatalog.empty.entries.isEmpty)
    }

    func testContentSignatureChangesOnALayoutEditEvenWithoutAVersionBump() {
        func design(_ value: String) -> IslandDesign {
            IslandDesign(json: [
                "id": "d",
                "version": 1,   // SAME version
                "presentations": ["expanded": ["type": "text", "value": value]],
            ])
        }
        // Same version, different tree → different signature (so it re-caches live).
        XCTAssertNotEqual(design("x").contentSignature, design("y").contentSignature)
        // Identical content → same signature (no spurious re-cache/push).
        XCTAssertEqual(design("x").contentSignature, design("x").contentSignature)
    }

    // MARK: Extras beyond the Dart file (offline plan accessors)

    func testOfflineScheduledItemsMergesNotificationsAndJobs() {
        let design = IslandDesign(json: [
            "id": "d",
            "notifications": [["at": 100, "title": "Legacy", "body": "b"]],
            "jobs": [[
                "at": 200,
                "notify": ["title": "Job", "body": "jb"],
                "action": ["skill": "run_code"],
            ]],
        ])
        let items = design.offlineScheduledItems
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(MoreJSON.text(items[0]["title"]), "Legacy")
        // A legacy notification never carries a tap action.
        XCTAssertNil(items[0]["action"])
        XCTAssertEqual(MoreJSON.text(items[1]["title"]), "Job")
        XCTAssertEqual(MoreJSON.text(items[1]["body"]), "jb")
        XCTAssertNotNil(items[1]["action"])
    }

    func testTimelineAndJobAccessorsTolerateMissingKeys() {
        let design = IslandDesign(json: ["id": "d"])
        XCTAssertTrue(design.timeline.isEmpty)
        XCTAssertTrue(design.notifications.isEmpty)
        XCTAssertTrue(design.jobs.isEmpty)
        XCTAssertTrue(design.offlineScheduledItems.isEmpty)
    }

    func testEntrySubtitleAndIcons() {
        let builtinOff = IslandCatalogEntry(json: ["id": "voice", "builtin": true,
                                                   "enabled": false, "priority": 100])
        XCTAssertEqual(builtinOff.subtitle, "Built-in · Off in Auto · Priority 100")
        XCTAssertEqual(builtinOff.iconName, "waveform")

        let coding = IslandCatalogEntry(json: ["id": "coding", "builtin": true, "priority": 50])
        XCTAssertEqual(coding.subtitle, "Built-in · Priority 50")
        XCTAssertEqual(coding.iconName, "chevron.left.forwardslash.chevron.right")

        let custom = IslandCatalogEntry(json: ["id": "deploy", "priority": 10])
        XCTAssertEqual(custom.subtitle, "Priority 10")
        XCTAssertEqual(custom.iconName, "square.grid.2x2")
    }

    func testCustomEntriesExcludeBuiltins() {
        let catalog = IslandCatalog(json: ["catalog": [
            ["id": "voice", "builtin": true],
            ["id": "deploy"],
        ]])
        XCTAssertEqual(catalog.customEntries.map(\.id), ["deploy"])
    }

    func testVersionAndPriorityParseFromStringsWithTheRightDefaults() {
        XCTAssertEqual(IslandParse.int("7", default: 1), 7)
        XCTAssertEqual(IslandParse.int(nil, default: 1), 1)
        XCTAssertEqual(IslandParse.int("junk", default: 1), 1)
        XCTAssertEqual(IslandParse.int(2.6, default: 1), 3)
        XCTAssertEqual(IslandCatalogEntry(json: ["id": "x"]).version, 1)
        XCTAssertEqual(IslandCatalogEntry(json: ["id": "x"]).priority, 0)
    }
}
