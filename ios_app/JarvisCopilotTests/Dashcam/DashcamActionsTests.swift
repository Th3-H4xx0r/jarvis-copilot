import XCTest
@testable import JarvisCopilot

/// The dashcam logic the phone views and the CarPlay screens share.
@MainActor
final class DashcamActionsTests: XCTestCase {

    // MARK: Mic

    func testMicReadsTheCamerasOwnOnOffCodes() {
        let items = [
            DashcamSettingItem(name: "rec_resolution", value: "4K", options: []),
            DashcamSettingItem(name: "mic", value: "2",
                               options: [.init(code: "2", label: "On"), .init(code: "5", label: "Off")]),
        ]
        XCTAssertEqual(DashcamMic.from(items), DashcamMic(on: true, onCode: "2", offCode: "5"))
    }

    func testMicDefaultsToOneAndZeroWithoutLabelledOptions() {
        let items = [DashcamSettingItem(name: "mic", value: "0", options: [])]
        XCTAssertEqual(DashcamMic.from(items), DashcamMic(on: false, onCode: "1", offCode: "0"))
    }

    func testNoMicSettingMeansNoMicControl() {
        XCTAssertNil(DashcamMic.from([DashcamSettingItem(name: "wdr", value: "1", options: [])]))
    }

    func testIsOnUnderstandsWordsDigitsAndNumbers() {
        XCTAssertEqual(DashcamControls.isOn("ON"), true)
        XCTAssertEqual(DashcamControls.isOn("0"), false)
        XCTAssertEqual(DashcamControls.isOn(NSNumber(value: 1)), true)
        XCTAssertNil(DashcamControls.isOn("Auto"))
    }

    // MARK: Status line

    func testSubtitleWithNothingToReport() {
        XCTAssertEqual(DashcamStatusText.subtitle(lastSync: nil, pendingUploads: 0, queuedDownloads: 0),
                       "Joins on its own when the camera is on")
    }

    func testSubtitleJoinsCountsWithDots() {
        XCTAssertEqual(DashcamStatusText.subtitle(lastSync: nil, pendingUploads: 3, queuedDownloads: 2),
                       "3 to upload · 2 to download")
    }

    func testSubtitleLeadsWithTheLastSync() {
        let text = DashcamStatusText.subtitle(lastSync: Date().addingTimeInterval(-120), pendingUploads: 1, queuedDownloads: 0)
        XCTAssertTrue(text.hasPrefix("Synced "), text)
        XCTAssertTrue(text.hasSuffix(" · 1 to upload"), text)
    }

    // MARK: Drives

    private func drive(_ id: String, start: Date, miles: Double, topMph: Double, minutes: Double = 10) -> DashcamDrive {
        DashcamDrive(json: ["id": id,
                            "start": ISO8601DateFormatter().string(from: start),
                            "end": ISO8601DateFormatter().string(from: start.addingTimeInterval(minutes * 60)),
                            "distance_m": miles * 1609.344,
                            "duration_s": minutes * 60,
                            "moving_s": minutes * 60,
                            "avg_mps": 10.0,
                            "max_mps": topMph / DashcamSpeed.mphPerMps])!
    }

    func testWeekSummaryCountsOnlyTheLastSevenDays() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let drives = [drive("a", start: now.addingTimeInterval(-3600), miles: 2, topMph: 40),
                      drive("b", start: now.addingTimeInterval(-3 * 86400), miles: 5, topMph: 65),
                      drive("c", start: now.addingTimeInterval(-9 * 86400), miles: 50, topMph: 90)]
        let week = DashcamDriveStats.week(drives, now: now)
        XCTAssertEqual(week.count, 2)
        XCTAssertEqual(week.distanceM, 7 * 1609.344, accuracy: 1)
        XCTAssertEqual(DashcamSpeed.mph(week.topMps) ?? 0, 65, accuracy: 0.5)
    }

    func testDrivesGroupByDayNewestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)           // a UTC afternoon
        let today = drive("t", start: now.addingTimeInterval(-600), miles: 1, topMph: 20)
        let earlierToday = drive("t0", start: now.addingTimeInterval(-7200), miles: 1, topMph: 20)
        let yesterday = drive("y", start: now.addingTimeInterval(-86400), miles: 1, topMph: 20)
        let groups = DashcamDriveStats.byDay([yesterday, earlierToday, today], calendar: cal, now: now)
        XCTAssertEqual(groups.map(\.0), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].1.map(\.id), ["t", "t0"])
    }

    func testDriveRowText() {
        let d = drive("x", start: Date(), miles: 12.4, topMph: 71, minutes: 25)
        XCTAssertEqual(DashcamDriveStats.detail(d), "12 mi · 25 min · top 71 mph")
        XCTAssertTrue(DashcamDriveStats.title(d).contains("–"))
    }

    // MARK: Camera setting titles

    func testSettingTitlesAreReadable() {
        XCTAssertEqual(DashcamCameraSettings.title("gsr_sensitivity"), "G‑sensor")
        XCTAssertEqual(DashcamCameraSettings.title("some_new_key"), "Some New Key")
    }

    /// As before the extraction: a mic state the camera doesn't report as on/off hides the button.
    func testUnreadableMicStateHidesTheButton() {
        XCTAssertNil(DashcamMic.from([DashcamSettingItem(name: "mic", value: "auto", options: [])]))
    }
}
