import Foundation
import XCTest
@testable import JarvisCopilot

/// The Integrations screen's model layer: what the list row says, what the
/// detail keeps, and how the plan card finds its plan in a tool result.
final class IntegrationsTests: XCTestCase {

    // MARK: The list row

    func testTheSubtitleCountsWhatThereIs() {
        let row = Integration(json: [
            "id": "casino", "name": "Casino Earnings",
            "schedule_count": 2, "enabled_schedule_count": 1,
            "record_count": 18, "skill_count": 1,
        ])
        XCTAssertEqual(row.subtitle, "2 schedules (1 off) · 18 records · 1 skill")
    }

    func testOneOfEachReadsSingular() {
        let row = Integration(json: ["id": "x", "schedule_count": 1,
                                     "enabled_schedule_count": 1, "skill_count": 1])
        XCTAssertEqual(row.subtitle, "1 schedule · 1 skill")
    }

    func testDocumentsStandInWhenThereAreNoRecords() {
        let row = Integration(json: ["id": "x", "document_count": 3])
        XCTAssertEqual(row.subtitle, "3 stored")
    }

    func testAnEmptyIntegrationSaysSo() {
        XCTAssertEqual(Integration(json: ["id": "general"]).subtitle, "nothing yet")
    }

    func testTheNameFallsBackToTheID() {
        XCTAssertEqual(Integration(json: ["id": "casino"]).name, "casino")
    }

    func testStatusDefaultsToActive() {
        XCTAssertFalse(Integration(json: ["id": "x"]).isPaused)
        XCTAssertTrue(Integration(json: ["id": "x", "status": "paused"]).isPaused)
    }

    // MARK: The detail

    func testTheMigrationsBookkeepingIsNotShownAsData() {
        let detail = IntegrationDetail(json: [
            "id": "casino",
            "documents": [["key": "summary"], ["key": "imported_files"]],
            "collections": [["name": "sessions", "count": 18]],
        ])
        XCTAssertEqual(detail.documents.map(\.key), ["summary"])
        XCTAssertFalse(detail.hasNothingStored)
    }

    func testDocumentSizesReadInTheRightUnit() {
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 900]).sizeLabel, "900 B")
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 4096]).sizeLabel, "4 KB")
        XCTAssertEqual(IntegrationDocument(json: ["key": "a", "bytes": 2_621_440]).sizeLabel, "2.5 MB")
    }

    func testARecordDrawsWhateverFieldsItCarries() {
        let record = IntegrationRecord(json: ["id": 4, "ts": 1_700_000_000,
                                              "game": "blackjack", "net": -120], index: 0)
        XCTAssertEqual(record.fields.map(\.key), ["game", "net"])   // ts and id are not fields
        XCTAssertEqual(record.fields.first?.value, "blackjack")
        XCTAssertFalse(record.timeLabel.isEmpty)
    }

    // MARK: Which integration owns a schedule

    func testAnUntaggedScheduleBelongsToGeneral() {
        XCTAssertEqual(CronJob(json: ["id": "j1"]).integrationID, "general")
        XCTAssertEqual(CronJob(json: ["id": "j1", "integration": "  Casino "]).integrationID, "casino")
    }

    // MARK: The plan card

    func testThePlanIDComesOutOfTheToolResult() {
        let tool = ToolInvocation(
            name: "integration_plan_propose",
            result: #"{"ok": true, "plan": {"id": "a1b2c3d4e5f6", "space_id": "gym-sessions"}}"#)
        XCTAssertEqual(IntegrationPlanCard.planID(in: tool), "a1b2c3d4e5f6")
    }

    func testThePlanIDSurvivesATruncatedResult() {
        // The chat keeps only the head of a long result; the id is near the front.
        let tool = ToolInvocation(
            name: "integration_plan_propose",
            result: #"{"ok": true, "plan": {"id": "a1b2c3d4e5f6", "space_id": "gym-ses"#)
        XCTAssertEqual(IntegrationPlanCard.planID(in: tool), "a1b2c3d4e5f6")
    }

    func testAnotherToolIsNeverAPlanCard() {
        let tool = ToolInvocation(name: "registry_query",
                                  result: #"{"ok": true, "plan": {"id": "nope"}}"#)
        XCTAssertNil(IntegrationPlanCard.planID(in: tool))
    }

    func testAPlanStillRunningHasNoIDYet() {
        XCTAssertNil(IntegrationPlanCard.planID(in: ToolInvocation(name: "integration_plan_propose")))
    }

    func testThePlanRendersWhatTheModelProposed() {
        let plan = IntegrationPlan(json: [
            "id": "p1", "space_id": "gym-sessions", "name": "Gym Sessions",
            "summary": "Logs your workouts.", "icon": "bolt", "status": "pending",
            "schedules": [["name": "weekly", "schedule": "0 19 * * 0", "purpose": "Sunday recap",
                           "prompt": "a prompt the card never shows"]],
            "collections": [["name": "sessions", "description": "one workout"]],
            "skills": [["name": "gym-logger", "purpose": "Log from a sentence."]],
        ])
        XCTAssertTrue(plan.isPending)
        XCTAssertEqual(plan.statusLabel, "PROPOSED")
        XCTAssertEqual(plan.schedules.map(\.when), ["0 19 * * 0"])
        XCTAssertEqual(plan.collections.first?.summary, "one workout")
        XCTAssertEqual(plan.skills.first?.summary, "Log from a sentence.")
    }

    func testADecidedPlanSaysWhatBecameOfIt() {
        XCTAssertEqual(IntegrationPlan(json: ["id": "p", "status": "approved"]).statusLabel, "CREATED")
        XCTAssertEqual(IntegrationPlan(json: ["id": "p", "status": "cancelled"]).statusLabel, "CANCELLED")
        XCTAssertFalse(IntegrationPlan(json: ["id": "p", "status": "approved"]).isPending)
    }
}

/// What the bug sweep found on this screen, kept fixed.
final class IntegrationsSweepTests: XCTestCase {

    private func row(_ id: String, status: String = "active", records: Int = 0) -> Integration {
        Integration(json: ["id": id, "name": id, "status": status, "record_count": records])
    }

    func testTheListNoticesMoreThanTheIDChanging() {
        // SwiftUI decides whether to redraw a row from this ==, so comparing only
        // the id meant pausing an integration never showed up until a relaunch.
        XCTAssertNotEqual(row("casino"), row("casino", status: "paused"))
        XCTAssertNotEqual(row("casino", records: 17), row("casino", records: 18))
        XCTAssertEqual(row("casino"), row("casino"))
        // Still one navigation value, so a push is not invalidated by a count.
        XCTAssertEqual(row("casino").hashValue, row("casino", records: 18).hashValue)
    }

    func testABooleanReadsAsTrueNotOne() {
        let record = IntegrationRecord(json: ["won": true, "lost": false, "hands": 12], index: 0)
        let fields = Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key, $0.value) })
        XCTAssertEqual(fields["won"], "true")
        XCTAssertEqual(fields["lost"], "false")
        XCTAssertEqual(fields["hands"], "12")
    }

    @MainActor
    func testPauseReadsTheLiveCopyNotThePushedOne() async {
        // The detail screen holds the value it was pushed with forever; deriving
        // the next status from it made Pause work once and Resume never.
        let store = IntegrationsStore(api: IntegrationsAPI())
        XCTAssertNil(store.current("casino"))
    }

    func testTheRouteCarriesTheIntegrationItWasTappedIn() {
        // Both cases carry an id because the store's idea of "open" can change
        // during the push animation.
        guard case .records(let id, let collection) = IntegrationDataRoute.records("casino", "sessions")
        else { return XCTFail("not a records route") }
        XCTAssertEqual(id, "casino")
        XCTAssertEqual(collection, "sessions")
        guard case .document(let docID, let key) = IntegrationDataRoute.document("casino", "summary")
        else { return XCTFail("not a document route") }
        XCTAssertEqual(docID, "casino")
        XCTAssertEqual(key, "summary")
    }
}

/// The More stack has to hold more than one kind of value.
///
/// It used to be `[MoreDestination]`, so a `NavigationLink(value: Integration)`
/// could not be appended and the push silently did nothing — the whole
/// Integrations detail screen was unreachable on a device, and no test caught it
/// because the app built and every model test passed.
@MainActor
final class MoreNavigationTests: XCTestCase {

    func testTheStackOpensAScreenThatPushesItsOwnValueTypes() {
        moreUIAHost(MorePage(initialPath: [.integrations]).environment(AppRouter()))
    }

    func testEveryDestinationStillOpens() {
        for destination in MoreDestination.allCases {
            moreUIAHost(MorePage(initialPath: [destination]).environment(AppRouter()))
        }
    }
}
