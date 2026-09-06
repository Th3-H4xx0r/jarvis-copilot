import Foundation
import XCTest
@testable import JarvisCopilot

/// `scheduleIslandNotifications` / `cancelIslandNotifications` from
/// `skills/common.dart`: a design's offline plan, pre-scheduled so it fires with
/// no network at all.
@MainActor
final class IslandPlanNotifierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(at offset: TimeInterval, title: String = "Boarding",
                      body: String = "Gate 42", action: JSONObject? = nil) -> JSONObject {
        var out: JSONObject = ["at": now.addingTimeInterval(offset).timeIntervalSince1970,
                               "title": title, "body": body]
        if let action { out["action"] = action }
        return out
    }

    func testFutureItemsBecomeScheduledNotifications() {
        let requests = IslandPlanNotifier.requests([item(at: 600)], now: now)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].title, "Boarding")
        XCTAssertEqual(requests[0].body, "Gate 42")
        XCTAssertEqual(requests[0].at, now.addingTimeInterval(600))
        XCTAssertEqual(requests[0].identifier, "\(IslandPlanNotifier.slotPrefix)0")
        XCTAssertTrue(requests[0].timeSensitive, "a plan alert that arrives quietly is useless")
    }

    func testPastAndUntitledItemsAreSkipped() {
        let items = [item(at: -60), item(at: 600, title: ""), item(at: 900, title: "Landing")]
        let requests = IslandPlanNotifier.requests(items, now: now)
        XCTAssertEqual(requests.map(\.title), ["Landing"])
        XCTAssertEqual(requests[0].identifier, "\(IslandPlanNotifier.slotPrefix)0",
                       "slots are assigned to the items that survive, not their input index")
    }

    func testMalformedTimestampsAreSkipped() {
        let requests = IslandPlanNotifier.requests(
            [["title": "no at"], ["at": "soon", "title": "x"], ["at": 0, "title": "epoch"]],
            now: now)
        XCTAssertTrue(requests.isEmpty)
    }

    func testAJobActionRidesInThePayloadSoATapCanRunIt() {
        let requests = IslandPlanNotifier.requests(
            [item(at: 600, action: ["skill": "open_url", "args": ["url": "https://x"]])], now: now)
        guard let payload = requests.first?.payload else { return XCTFail("no payload") }
        let decoded = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["__jcIslandAction"] as? Bool, true)
        let action = decoded?["action"] as? [String: Any]
        XCTAssertEqual(action?["skill"] as? String, "open_url")
    }

    func testAnActionWithoutASkillCarriesNoPayload() {
        let requests = IslandPlanNotifier.requests(
            [item(at: 600, action: ["args": ["x": 1]])], now: now)
        XCTAssertNil(requests.first?.payload)
    }

    func testTheSlotBlockIsBounded() {
        let items = (1...100).map { item(at: TimeInterval($0 * 60), title: "n\($0)") }
        let requests = IslandPlanNotifier.requests(items, now: now)
        XCTAssertEqual(requests.count, IslandPlanNotifier.slotCount)
        XCTAssertEqual(Set(requests.compactMap(\.identifier)).count, IslandPlanNotifier.slotCount,
                       "every slot id is distinct, so a reschedule replaces cleanly")
    }

    func testAnUnchangedPlanIsNotRescheduled() async {
        let notifier = MockNotifier()
        let plan = IslandPlanNotifier(notifier: notifier, now: { self.now })
        let design = IslandDesign(json: [
            "id": "flight", "version": 1, "root": ["type": "text"],
            "jobs": [["at": now.addingTimeInterval(600).timeIntervalSince1970,
                      "notify": ["title": "Boarding"]]],
        ])

        plan.sync(design)
        await servicesWaitUntil { !notifier.posted.isEmpty }
        let after = notifier.posted.count

        plan.sync(design)
        plan.sync(design)
        XCTAssertEqual(notifier.posted.count, after,
                       "the coordinator pushes every ~5 s — churning the scheduler is the bug")
    }

    func testSwitchingAwayFromADesignCancelsItsPlan() async {
        let notifier = MockNotifier()
        let plan = IslandPlanNotifier(notifier: notifier, now: { self.now })
        let design = IslandDesign(json: [
            "id": "flight", "version": 1, "root": ["type": "text"],
            "jobs": [["at": now.addingTimeInterval(600).timeIntervalSince1970,
                      "notify": ["title": "Boarding"]]],
        ])
        plan.sync(design)
        await servicesWaitUntil { !notifier.posted.isEmpty }

        plan.sync(nil)
        await servicesWaitUntil { !notifier.cancelled.isEmpty }
        XCTAssertTrue(notifier.cancelled.contains("\(IslandPlanNotifier.slotPrefix)0"))
    }
}
