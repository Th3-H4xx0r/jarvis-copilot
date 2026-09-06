import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/island_offline_test.dart`, case for case.
final class IslandOfflineTests: XCTestCase {

    private let timeline: [JSONObject] = [
        ["at": 100, "data": ["phase": "Boarding"]],
        ["at": 200, "data": ["phase": "In flight"]],
        ["at": 300, "data": ["phase": "Landed"]],
    ]

    // MARK: currentKeyframeData

    func testEmptyTimelineGivesEmpty() {
        XCTAssertTrue(IslandOffline.currentKeyframeData([], 250).isEmpty)
    }

    func testBeforeTheFirstKeyframeGivesEmpty() {
        XCTAssertTrue(IslandOffline.currentKeyframeData(timeline, 50).isEmpty)
    }

    func testPicksTheLatestKeyframeAtOrBeforeNow() {
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(timeline, 250)["phase"]),
                       "In flight")
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(timeline, 200)["phase"]),
                       "In flight")
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(timeline, 999)["phase"]),
                       "Landed")
    }

    func testUnsortedTimelineStillResolvesCorrectly() {
        let unsorted: [JSONObject] = [
            ["at": 300, "data": ["p": "c"]],
            ["at": 100, "data": ["p": "a"]],
            ["at": 200, "data": ["p": "b"]],
        ]
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(unsorted, 250)["p"]), "b")
    }

    func testMalformedEntriesAreSkipped() {
        let malformed: [JSONObject] = [
            ["at": "nope", "data": [:]],
            ["at": 100, "data": ["p": "a"]],
        ]
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(malformed, 150)["p"]), "a")
    }

    func testNumericStringAtIsAccepted() {
        let stringy: [JSONObject] = [["at": "100", "data": ["p": "a"]]]
        XCTAssertEqual(MoreJSON.text(IslandOffline.currentKeyframeData(stringy, 150)["p"]), "a")
    }

    // MARK: scheduledItemsSignature

    func testStableForEqualListsSensitiveToChange() {
        let a: [JSONObject] = [["at": 1, "title": "x", "body": "y"]]
        let b: [JSONObject] = [["at": 1, "title": "x", "body": "y"]]
        let c: [JSONObject] = [["at": 2, "title": "x", "body": "y"]]
        XCTAssertEqual(IslandOffline.scheduledItemsSignature(a),
                       IslandOffline.scheduledItemsSignature(b))
        XCTAssertNotEqual(IslandOffline.scheduledItemsSignature(a),
                          IslandOffline.scheduledItemsSignature(c))
    }

    func testOrderIndependentBecauseItIsSortedInternally() {
        let a: [JSONObject] = [["at": 1, "title": "x"], ["at": 2, "title": "y"]]
        let b: [JSONObject] = [["at": 2, "title": "y"], ["at": 1, "title": "x"]]
        XCTAssertEqual(IslandOffline.scheduledItemsSignature(a),
                       IslandOffline.scheduledItemsSignature(b))
    }

    func testAChangedTapActionReschedules() {
        let base: [JSONObject] = [["at": 1, "title": "x"]]
        let withA: [JSONObject] = [["at": 1, "title": "x", "action": ["skill": "run_code"]]]
        let withB: [JSONObject] = [["at": 1, "title": "x", "action": ["skill": "set_alarm"]]]
        XCTAssertNotEqual(IslandOffline.scheduledItemsSignature(base),
                          IslandOffline.scheduledItemsSignature(withA))
        XCTAssertNotEqual(IslandOffline.scheduledItemsSignature(withA),
                          IslandOffline.scheduledItemsSignature(withB))
    }

    func testControlByteSeparatorsAvoidFieldRowCollisions() {
        // "1|x"-style content must not let two different lists collide.
        let a: [JSONObject] = [["at": 1, "title": "x", "body": "yz"]]
        let b: [JSONObject] = [["at": 1, "title": "xy", "body": "z"]]
        XCTAssertNotEqual(IslandOffline.scheduledItemsSignature(a),
                          IslandOffline.scheduledItemsSignature(b))
    }

    func testEmptyListGivesEmptySignature() {
        XCTAssertEqual(IslandOffline.scheduledItemsSignature([]), "")
    }

    func testActionSignatureIsKeyOrderIndependent() {
        // Canonical (sorted-key) JSON means the same action written two ways is
        // still one signature — otherwise the scheduler would churn.
        let one: [JSONObject] = [["at": 1, "title": "x",
                                  "action": ["skill": "s", "args": ["a": 1, "b": 2]]]]
        let two: [JSONObject] = [["at": 1, "title": "x",
                                  "action": ["args": ["b": 2, "a": 1], "skill": "s"]]]
        XCTAssertEqual(IslandOffline.scheduledItemsSignature(one),
                       IslandOffline.scheduledItemsSignature(two))
    }

    // MARK: IslandSync (content-keyed cache pushes)

    func testSyncPushesOnlyChangedDesignsAndClearsOnRemoval() async {
        let cache = SpyIslandCache()
        let sync = IslandSync(cache: cache)

        func design(_ id: String, _ value: String) -> IslandDesign {
            IslandDesign(json: ["id": id, "version": 1,
                                "presentations": ["expanded": ["type": "text", "value": value]]])
        }

        await sync.sync([design("a", "1"), design("b", "1")])
        var pushed = await cache.pushedIDs
        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed[0].sorted(), ["a", "b"])

        // Nothing changed → no channel chatter at all.
        await sync.sync([design("a", "1"), design("b", "1")])
        pushed = await cache.pushedIDs
        XCTAssertEqual(pushed.count, 1)

        // A layout edit with the SAME version must still re-push.
        await sync.sync([design("a", "2"), design("b", "1")])
        pushed = await cache.pushedIDs
        XCTAssertEqual(pushed.count, 2)
        XCTAssertEqual(pushed[1], ["a"])

        // A design disappearing clears the whole cache and re-pushes.
        await sync.sync([design("a", "2")])
        let clears = await cache.clears
        pushed = await cache.pushedIDs
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(pushed.count, 3)
        XCTAssertEqual(pushed[2], ["a"])
    }

    func testSyncPayloadCarriesIDVersionAndJSON() async {
        let cache = SpyIslandCache()
        let sync = IslandSync(cache: cache)
        await sync.sync([IslandDesign(json: ["id": "a", "version": 4])])

        let pushes = await cache.pushes
        XCTAssertEqual(pushes.count, 1)
        XCTAssertEqual(MoreJSON.text(pushes[0][0]["id"]), "a")
        XCTAssertEqual(MoreJSON.int(pushes[0][0]["version"]), 4)
        XCTAssertFalse(MoreJSON.text(pushes[0][0]["json"]).isEmpty)
    }

    func testSyncResetForcesTheNextPush() async {
        let cache = SpyIslandCache()
        let sync = IslandSync(cache: cache)
        let designs = [IslandDesign(json: ["id": "a", "version": 1])]
        await sync.sync(designs)
        await sync.reset()
        await sync.sync(designs)
        let pushes = await cache.pushes
        XCTAssertEqual(pushes.count, 2)
    }
}
