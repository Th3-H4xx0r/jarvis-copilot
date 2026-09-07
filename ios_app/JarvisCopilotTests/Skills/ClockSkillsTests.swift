import XCTest
@testable import JarvisCopilot

final class ClockSkillsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_757_000_000)

    func testStopwatchStartLapStopRead() async throws {
        let sw = MockStopwatch()
        var clock = t0
        let skill = ClockSkills.stopwatch(sw, now: { clock })
        var r = try await skill.run(["action": "start"])
        XCTAssertEqual(r["running"] as? Bool, true)
        clock = t0.addingTimeInterval(30)
        r = try await skill.run(["action": "lap"])
        XCTAssertEqual(r["lap"] as? String, "00:30.0")
        clock = t0.addingTimeInterval(45.5)
        r = try await skill.run(["action": "stop"])
        XCTAssertEqual(r["running"] as? Bool, false)
        XCTAssertEqual(r["elapsed_seconds"] as? Double, 45.5)
        clock = t0.addingTimeInterval(1000)
        r = try await skill.run(["action": "read"])
        XCTAssertEqual(r["elapsed"] as? String, "00:45.5")
        XCTAssertEqual(r["lap_count"] as? Int, 1)
        XCTAssertEqual(sw.actions, [.start, .lap, .stop, .read])
    }

    func testStopwatchSynonyms() async throws {
        let sw = MockStopwatch()
        let skill = ClockSkills.stopwatch(sw, now: { self.t0 })
        _ = try await skill.run(["action": "pause"])
        _ = try await skill.run(["action": "resume"])
        _ = try await skill.run(["action": "clear"])
        _ = try await skill.run(["action": "status"])
        XCTAssertEqual(sw.actions, [.stop, .start, .reset, .read])
    }

    func testStopwatchRejectsAnUnknownAction() async {
        let skill = ClockSkills.stopwatch(MockStopwatch(), now: { self.t0 })
        do {
            _ = try await skill.run(["action": "explode"])
            XCTFail("expected badArgument")
        } catch let e as SkillError {
            if case .badArgument = e {} else { XCTFail("wrong error \(e)") }
        } catch { XCTFail("wrong error \(error)") }
    }

    func testWorldTimeByCityAndZone() async throws {
        // 1_757_000_000 = 2025-09-04 15:33:20 UTC
        let skill = ClockSkills.worldTime(now: { self.t0 })
        let tokyo = try await skill.run(["place": "Tokyo"])
        XCTAssertEqual(tokyo["found"] as? Bool, true)
        XCTAssertEqual(tokyo["zone"] as? String, "Asia/Tokyo")
        XCTAssertEqual(tokyo["time"] as? String, "00:33")
        XCTAssertEqual(tokyo["utc_offset"] as? String, "UTC+09:00")
        let paris = try await skill.run(["place": "Europe/Paris"])
        XCTAssertEqual(paris["time"] as? String, "17:33")
        let kolkata = try await skill.run(["place": "Kolkata"])
        XCTAssertEqual(kolkata["utc_offset"] as? String, "UTC+05:30")
    }

    func testWorldTimeUnknownPlace() async throws {
        let r = try await ClockSkills.worldTime(now: { self.t0 }).run(["place": "Atlantis"])
        XCTAssertEqual(r["found"] as? Bool, false)
    }

    func testWorldTimeNeedsAPlace() async {
        do {
            _ = try await ClockSkills.worldTime(now: { self.t0 }).run([:])
            XCTFail("expected badArgument")
        } catch {}
    }
}
