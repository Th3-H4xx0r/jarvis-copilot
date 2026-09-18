import XCTest
@testable import JarvisCopilot

/// The phone reads Jarvis Health's days through the ring's own day model, so
/// the existing cards draw server data unchanged.
final class HealthWireTests: XCTestCase {
    private let dayJSON = """
    {"date":"2026-09-17","timezone":"America/Chicago","utc_offset":-18000,
     "sleep":[{"start":"2026-09-17T04:30:00Z","end":"2026-09-17T12:30:00Z","stages":[[2,90],[3,300],[4,90]]}],
     "heart_rate":{"start":"2026-09-17T05:00:00Z","interval_minutes":5,"values":[0,58,60]},
     "spo2":{"start":"2026-09-17T05:00:00Z","interval_minutes":60,"values":[97,96]},
     "steps":{"start":"2026-09-17T05:00:00Z","interval_minutes":15,"values":[0,120,300]},
     "activity":{"steps":420,"active_minutes":12,"kilocalories":31,"distance_meters":300}}
    """

    func testAServerDayBecomesARingDayTheCardsCanDraw() throws {
        let ring = try JSONDecoder().decode(HealthWireDay.self, from: Data(dayJSON.utf8)).ringDay()
        XCTAssertEqual(ring.heartRate?.values, [0, 58, 60])
        XCTAssertEqual(ring.stepSlots.map(\.steps), [120, 300])
        XCTAssertEqual(ring.stepSlots.map(\.slot), [1, 2])
        XCTAssertEqual(ring.sleep.first?.stages.first?.stage, RingSleepStage.deep, "SDK deep (2) is the ring's deep")
        XCTAssertEqual(ring.spo2?.min, [97, 96])
        XCTAssertEqual(ring.activity?.steps, 420)
        XCTAssertEqual(ring.activity?.kilocalories ?? 0, 31, accuracy: 0.001)
    }

    func testTheBatteryAndWindowDecode() throws {
        let json = """
        {"start":"2026-09-17T12:37:00Z","end":"2026-09-17T20:00:00Z","minutes":443,"no_wake":false,
         "day":null,"stats":{"steps":1653},
         "battery":{"level":82.4,"wake_level":91.9,"band":"High","drained":9.5,
                    "biggest_drain":{"start":"2026-09-17T16:30:00Z","end":"2026-09-17T17:00:00Z","points":1.6},
                    "curve":[{"at":"2026-09-17T13:00:00Z","level":91.0}]}}
        """
        let now = try HealthClient.decodeForTests(HealthNow.self, json: json)
        XCTAssertEqual(now.battery.level, 82.4)
        XCTAssertEqual(now.battery.curve.count, 1)
        XCTAssertEqual(now.battery.biggestDrain?.points, 1.6)
        XCTAssertEqual(now.minutes, 443)
    }

    func testTheDayUploadCarriesAStepsSeriesAndItsDevice() {
        var day = RingDay(date: "2026-09-17")
        day.stepSlots = [RingStepSlot(slot: 4, steps: 120, calories: 5, distanceMeters: 80)]
        let payload = HealthDayPayload.make(day, key: "2026-09-17", deviceID: "B6CE93C4-5680")
        let steps = payload["steps"] as? [String: Any]
        XCTAssertEqual(steps?["interval_minutes"] as? Int, 15)
        XCTAssertEqual((steps?["values"] as? [Int])?.count, 96)
        XCTAssertEqual((steps?["values"] as? [Int])?[4], 120)
        XCTAssertEqual(payload["device_id"] as? String, "B6CE93C4-5680")
    }

    func testEveryWearableTalksToTheOneSharedIntegration() {
        XCTAssertEqual(HealthSpace.id(forRing: "B6CE93C4-5680"), "jarvis-health")
        XCTAssertEqual(HealthClient.settingsSource, "health-settings")
    }
}
