import XCTest
@testable import JarvisCopilot

/// The phone's own copy of the voice log: a car test can be read afterwards over
/// the cable, where the live console capture dies whenever the phone drops off.
final class VoiceLogFileTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceLogFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testLinesAreKeptInOrderWithTheirDay() throws {
        let dir = try makeDir()
        let log = VoiceLogFile(directory: dir, maxBytes: 10_000)
        let day = Date(timeIntervalSince1970: 1_792_200_000)
        log.append("[voice] 18:43:21.192 startRequested: idle→connecting", at: day)
        log.append("[cp-diag] 1792194201.192 overlay presented=true", at: day)
        log.flush()
        let lines = read(log.current).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[voice] 18:43:21.192 startRequested: idle→connecting"))
        XCTAssertTrue(lines[1].hasSuffix("overlay presented=true"))
        XCTAssertTrue(lines[0].hasPrefix(VoiceLogFile.dayStamp(day)), "a line says which day it was")
    }

    /// Bounded: past the cap the file rolls over once, so the newest lines and
    /// the ones just before them are both there, and nothing grows forever.
    func testRollsOverPastTheCapKeepingTheNewest() throws {
        let dir = try makeDir()
        let log = VoiceLogFile(directory: dir, maxBytes: 200)
        for i in 0..<40 { log.append("line \(i)") }
        log.flush()
        let current = read(log.current)
        let previous = read(log.previous)
        XCTAssertTrue(current.contains("line 39"), "the newest line is in the live file")
        XCTAssertFalse(previous.isEmpty, "the one before it was kept")
        XCTAssertLessThanOrEqual(current.utf8.count, 200 + 60)
    }

    func testSurvivesARelaunch() throws {
        let dir = try makeDir()
        let first = VoiceLogFile(directory: dir, maxBytes: 10_000)
        first.append("before")
        first.flush()
        let again = VoiceLogFile(directory: dir, maxBytes: 10_000)
        again.append("after")
        again.flush()
        let text = read(again.current)
        XCTAssertTrue(text.contains("before") && text.contains("after"), "appends, never truncates on launch")
    }

    /// The newest lines, oldest first, reaching back into the rolled-over file — what the
    /// server reads over the bridge when the phone isn't on the cable.
    func testTailReturnsTheNewestLinesAcrossTheRollover() throws {
        let dir = try makeDir()
        let log = VoiceLogFile(directory: dir, maxBytes: 200)
        for i in 0..<40 { log.append("line \(i)") }
        let tail = log.tail(lines: 12)
        XCTAssertEqual(tail.count, 12)
        XCTAssertTrue(tail.last?.hasSuffix("line 39") == true)
        XCTAssertTrue(tail.first?.hasSuffix("line 28") == true, "\(tail)")
    }

    func testTailKeepsOnlyLinesWithTheFilter() throws {
        let dir = try makeDir()
        let log = VoiceLogFile(directory: dir, maxBytes: 10_000)
        log.append("[voice] startup: total=4900ms")
        log.append("[spotify] play")
        log.append("[voice] mic started")
        XCTAssertEqual(log.tail(lines: 10, containing: "[voice]").count, 2)
        XCTAssertEqual(log.tail(lines: 1, containing: "[voice]").first?.hasSuffix("mic started"), true)
    }

    /// `voice_log`: the server reads the newest lines, capped, filtered when asked.
    func testTheVoiceLogSkillReturnsTheNewestLinesCapped() async throws {
        let dir = try makeDir()
        let log = VoiceLogFile(directory: dir, maxBytes: 100_000)
        for i in 0..<50 { log.append("[voice] line \(i)") }
        log.append("[cp-diag] overlay presented=true")
        let skill = VoiceLogFile.skill(log)
        XCTAssertEqual(skill.name, "voice_log")
        XCTAssertFalse(skill.requiresForeground, "readable with Jarvis in the background")
        let all = try await skill.run(["lines": 5])
        XCTAssertEqual((all["lines"] as? [String])?.count, 5)
        XCTAssertEqual((all["lines"] as? [String])?.last?.hasSuffix("overlay presented=true"), true)
        let voice = try await skill.run(["lines": 3, "contains": "[voice]"])
        XCTAssertEqual((voice["lines"] as? [String])?.last?.hasSuffix("line 49"), true)
        let huge = try await skill.run(["lines": 1_000_000])
        XCTAssertLessThanOrEqual((huge["lines"] as? [String])?.count ?? 0, VoiceLogFile.maxTailLines)
    }
}
