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
        XCTAssertNil(now.wake, "an older server sends no wake")
    }

    /// Today runs from bedtime: the server says when the night ended and
    /// where the battery stood at each end of it.
    func testTodayCarriesTheNightItOpensWith() throws {
        let json = """
        {"start":"2026-09-17T04:30:00Z","end":"2026-09-17T20:00:00Z","wake":"2026-09-17T12:37:00Z",
         "minutes":930,"no_wake":false,"day":null,
         "battery":{"level":84.0,"band":"High","bed_level":39.5,"wake_level":90.0,"charged":50.5,"drained":6.0,
                    "bed_at":"2026-09-17T04:30:00Z","wake_at":"2026-09-17T12:37:00Z","no_sleep":false,
                    "curve":[{"at":"2026-09-17T04:30:00Z","level":39.5}]}}
        """
        let now = try HealthClient.decodeForTests(HealthNow.self, json: json)
        XCTAssertEqual(now.wake, now.battery.wakeAt)
        XCTAssertEqual(now.battery.bedAt, now.start)
        XCTAssertEqual(now.battery.bedLevel, 39.5)
        XCTAssertEqual(now.battery.charged, 50.5)
        XCTAssertEqual(HealthTabModel.scoresDate(now), RingDates.dayKey(now.wake!))
    }

    /// Any day is bedtime to bedtime now, with the week's sleep debt beside it.
    func testADayCarriesItsWindowAndSleepDebt() throws {
        let json = """
        {"date":"2026-09-17","start":"2026-09-17T04:30:00Z","end":"2026-09-18T07:03:00Z",
         "wake":"2026-09-17T12:37:00Z","minutes":1593,"no_wake":false,"has_data":true,"day":null,
         "battery":{"level":45.9,"band":"Low","curve":[]},
         "sleep_debt":{"goal":480,"debt":190,"band":"Low","average":452,"short_nights":3,"measured":6,
                       "nights":[{"date":"2026-09-17","asleep":null,"debt":190,"band":"Low"}]}}
        """
        let day = try HealthClient.decodeForTests(HealthDayResponse.self, json: json)
        XCTAssertEqual(try XCTUnwrap(day.end).timeIntervalSince(try XCTUnwrap(day.start)), 1593 * 60, accuracy: 60)
        XCTAssertEqual(day.sleepDebt?.debt, 190)
        XCTAssertEqual(day.sleepDebt?.shortNights, 3)
        XCTAssertNil(day.sleepDebt?.nights.first?.asleep, "an unrecorded night is not a sleepless one")
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

/// Measure results live in the ring's own history, not the server's day: the
/// Health tab moves them onto today's clock, which starts the midnight before bedtime.
final class HealthSpotReadingTests: XCTestCase {
    func testTheRingsReadingsMoveOntoTodaysClock() {
        var ringToday = RingDay(date: "2026-09-18")
        ringToday.instantHeartRate = [RingTimedValue(minute: 600, value: 74)]
        var ringYesterday = RingDay(date: "2026-09-17")
        ringYesterday.manualSpO2 = [RingTimedValue(minute: 600, value: 97),        // before bedtime: not today
                                    RingTimedValue(minute: 1420, value: 96)]       // in bed at 23:30

        var window = RingDay(date: "today")
        window.addSpots(from: ringYesterday, shift: 0, from: 1410)
        window.addSpots(from: ringToday, shift: 1440, from: 1410)

        XCTAssertEqual(window.instantHeartRate, [RingTimedValue(minute: 2040, value: 74)])
        XCTAssertEqual(window.manualSpO2, [RingTimedValue(minute: 1420, value: 96)])
        XCTAssertEqual(window.summary.heartRateLatest, 74, "a reading just taken is the card's latest")
    }

    /// A finished day ends at the next bedtime: a reading after it is tomorrow's.
    func testAFinishedDayKeepsOnlyItsOwnReadings() {
        var ring = RingDay(date: "2026-09-18")
        ring.instantHeartRate = [RingTimedValue(minute: 60, value: 70),       // 01:00, before bed
                                 RingTimedValue(minute: 600, value: 80)]      // 10:00, the next day's
        var yesterday = RingDay(date: "2026-09-17")
        yesterday.addSpots(from: ring, shift: 1440, from: 0, to: 1440 + 123)  // bed at 02:03
        XCTAssertEqual(yesterday.instantHeartRate, [RingTimedValue(minute: 1500, value: 70)])
    }
}

/// A workout just saved shows on today before the server has it.
@MainActor
final class HealthSavedWorkoutTests: XCTestCase {
    func testASavedWorkoutShowsOnTodayAtOnce() {
        let model = HealthTabModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let start = Date()
        let run = RingWorkout(sport: 7, sportName: "Run", start: start, end: start.addingTimeInterval(1800),
                              activeSeconds: 1800, steps: 4000, distanceMeters: 4100, distanceSource: "gps",
                              kilocalories: 300, heartRateAverage: 140, heartRateMax: 165, heartRates: [],
                              zoneSeconds: [0, 0, 0, 0, 0])
        model.noteSaved(run)
        model.noteSaved(run)
        XCTAssertEqual(model.workouts[HealthTabModel.windowKey]?.count, 1, "saved twice is still one")
    }
}
