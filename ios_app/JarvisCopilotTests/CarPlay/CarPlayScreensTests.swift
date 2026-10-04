import XCTest
@testable import JarvisCopilot

/// The CarPlay screens are pure functions of store state: these pin what each
/// screen lists, which rows act, and that nothing ever pushes past depth 3.
@MainActor
final class CarPlayScreensTests: XCTestCase {

    // MARK: Helpers

    private func rows(_ sections: [CarPlaySection]) -> [CarPlayRow] { sections.flatMap(\.rows) }
    private func row(_ sections: [CarPlaySection], _ title: String) -> CarPlayRow? {
        rows(sections).first { $0.title == title }
    }
    private func pushedScreens(_ sections: [CarPlaySection]) -> [CarPlayScreen] {
        rows(sections).compactMap { if case .push(let s) = $0.action { return s } else { return nil } }
    }
    private func clip(_ id: String, kind: String = "normal", lens: String = "front", onCamera: Bool = true,
                      phone: String = "none", destinations: [String: Any] = [:], thumb: Bool = false,
                      start: String = "2026-10-03T20:42:00Z") -> DashcamServerClip {
        DashcamServerClip(json: ["id": id, "path": "/DCIM/\(id).TS", "kind": kind, "lens": lens, "start": start,
                                 "duration_s": 60, "size": 250_000_000, "on_camera": onCamera, "has_thumb": thumb,
                                 "phone": ["state": phone], "destinations": destinations])!
    }
    private func dashcamInput(onCamera: Bool = true, recording: Bool? = true, clips: [DashcamServerClip] = [],
                              mic: DashcamMic? = nil, canReconnect: Bool = true, passActive: Bool = false,
                              parked: Bool = true) -> CarPlayDashcamInput {
        CarPlayDashcamInput(onCamera: onCamera, phaseLabel: "Up to date", recording: recording, sdFreeBytes: 12_300_000_000,
                            subtitle: "Synced 2 min ago", downloading: nil, uploading: nil, cloudBackupOn: true,
                            uploadNote: nil, passActive: passActive, mic: mic, canReconnect: canReconnect,
                            filter: .all, clips: clips, canLoadMore: false, libraryError: nil, parked: parked)
    }

    // MARK: Not paired

    func testNotPairedIsOneReadableRow() {
        let r = rows(CarPlayScreens.notPaired)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].title, "Pair Jarvis on your iPhone")
        XCTAssertEqual(r[0].action, .none)
    }

    // MARK: Voice tab

    /// Before anything is said the Voice tab is just its header (orb, state, Talk).
    func testVoiceTabIsJustItsHeaderBeforeAConversation() {
        XCTAssertTrue(rows(CarPlayScreens.voiceTab(nil, speaking: false)).isEmpty)
    }

    /// The reply in the big row text as it's spoken (the newest words), what you said under it.
    func testVoiceTabShowsTheReplyAsItIsSpoken() {
        let text = CarPlayScreens.voiceText(heard: "Are you there?", reply: "Here, sir. The worker is waiting.", spokenWords: 3)
        let r = rows(CarPlayScreens.voiceTab(text, speaking: true))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].title, "Here, sir. The")
        XCTAssertEqual(r[0].detail, "Are you there?")
        XCTAssertEqual(r[0].action, .none)
    }

    /// Done speaking (or a text-only reply): the whole reply.
    func testTheWholeReplyShowsOnceSpoken() {
        let text = CarPlayScreens.voiceText(heard: "Are you there?", reply: "Here, sir.", spokenWords: 0)
        XCTAssertEqual(rows(CarPlayScreens.voiceTab(text, speaking: false)).first?.title, "Here, sir.")
    }

    /// While Jarvis thinks there's no reply yet: what you said is the line.
    func testOnlyWhatYouSaidWhileJarvisThinks() {
        let text = CarPlayScreens.voiceText(heard: "Are you there?", reply: "", spokenWords: 0)
        let r = rows(CarPlayScreens.voiceTab(text, speaking: false))
        XCTAssertEqual(r.first?.title, "Are you there?")
        XCTAssertNil(r.first?.detail)
    }

    /// A long reply shows its newest words, cut at a word, so the line keeps up with the voice.
    func testALongReplyShowsItsNewestWords() {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let title = rows(CarPlayScreens.voiceTab(CarPlayScreens.voiceText(heard: "", reply: long, spokenWords: 40), speaking: true))[0].title
        XCTAssertTrue(title.hasPrefix("…"), title)
        XCTAssertTrue(title.hasSuffix("word40"), title)
        XCTAssertLessThanOrEqual(title.count, CarPlayScreens.replyLength + 1)
        XCTAssertFalse(title.dropFirst().hasPrefix(" "))
    }

    /// Like the phone: what you said, then Jarvis's reply with the spoken words lit.
    func testVoiceTextSplitsTheReplyAtTheSpokenWord() {
        let t = CarPlayScreens.voiceText(heard: "Are you there?", reply: "Here, sir. The worker is waiting.", spokenWords: 3)
        XCTAssertEqual(t?.heard, "Are you there?")
        XCTAssertEqual(t?.spoken, "Here, sir. The")
        XCTAssertEqual(t?.unspoken, " worker is waiting.")
    }

    func testVoiceTextBeforeAndAfterSpeaking() {
        XCTAssertEqual(CarPlayScreens.voiceText(heard: "", reply: "Two words", spokenWords: 0)?.unspoken, "Two words")
        XCTAssertEqual(CarPlayScreens.voiceText(heard: "", reply: "Two words", spokenWords: 0)?.spoken, "")
        XCTAssertEqual(CarPlayScreens.voiceText(heard: "", reply: "Two words", spokenWords: 9)?.spoken, "Two words")
        XCTAssertNil(CarPlayScreens.voiceText(heard: "  ", reply: "", spokenWords: 0), "nothing said yet: no text")
        XCTAssertNil(CarPlayScreens.voiceText(heard: "Hi", reply: "", spokenWords: 0)?.spoken.nilIfEmpty)
    }

    // MARK: Wearables tab (car-enabled only)

    func testWearablesTabListsCarDevicesAndOpensTheDashcamScreens() {
        let s = CarPlayScreens.wearablesTab([
            CarPlayCarDevice(id: "cam1", name: "A4", status: "Up to date · Recording", connected: true, isDashcam: true),
            CarPlayCarDevice(id: "x", name: "Future thing", status: "Not connected", connected: false, isDashcam: false),
        ])
        XCTAssertEqual(rows(s).map(\.title), ["A4", "Future thing"])
        XCTAssertEqual(row(s, "A4")?.action, .push(.dashcam))
        XCTAssertEqual(row(s, "A4")?.detail, "Up to date · Recording")
        XCTAssertEqual(row(s, "Future thing")?.action, .push(.device(id: "x")))
    }

    func testNoCarDevicesSaysHowToAddOne() {
        let r = rows(CarPlayScreens.wearablesTab([]))
        XCTAssertEqual(r.map(\.title), ["No car wearables yet"])
        XCTAssertEqual(r[0].action, .none)
    }

    /// Only device types that opt in with `carEnabled` reach the car.
    func testOnlyCarEnabledDeviceTypesQualify() {
        XCTAssertTrue(DashcamDevice.shared.carEnabled)
        XCTAssertFalse(PhoneDevice().carEnabled)
    }

    /// A car device without its own screen shows its status and the scalar state it reports.
    func testGenericCarDeviceShowsItsState() {
        let info = CarPlayScreens.carDevice(name: "Thing", connected: true,
                                            snapshot: ["battery_pct": 80, "mode": "eco", "nested": ["a": 1], "on": true])
        XCTAssertEqual(info.title, "Thing")
        XCTAssertEqual(info.items, [CarPlayInfoItem(title: "Status", detail: "Connected"),
                                    CarPlayInfoItem(title: "Battery Pct", detail: "80"),
                                    CarPlayInfoItem(title: "Mode", detail: "eco"),
                                    CarPlayInfoItem(title: "On", detail: "Yes")])
    }

    // MARK: Dashcam

    func testAwayFromTheCameraHidesControlsAndDisablesSync() {
        let s = CarPlayScreens.dashcam(dashcamInput(onCamera: false, recording: nil))
        XCTAssertNil(s.first { $0.title == "Controls" })
        XCTAssertEqual(rows(s)[0].title, "Away from the camera")
        XCTAssertEqual(row(s, "Sync now")?.enabled, false)
        XCTAssertEqual(row(s, "Reconnect")?.action, .dashcam(.reconnect))
    }

    func testReconnectNeedsASavedPassword() {
        let s = CarPlayScreens.dashcam(dashcamInput(onCamera: false, recording: nil, canReconnect: false))
        XCTAssertEqual(row(s, "Reconnect")?.enabled, false)
    }

    func testOnTheCameraTheControlsFollowRecording() {
        let recording = CarPlayScreens.dashcam(dashcamInput(recording: true, mic: DashcamMic(on: true, onCode: "1", offCode: "0")))
        XCTAssertEqual(row(recording, "Stop recording")?.action, .dashcam(.record))
        XCTAssertEqual(row(recording, "Mic on")?.action, .dashcam(.mic(false)))
        XCTAssertNotNil(row(recording, "Take a photo"))
        XCTAssertNotNil(row(recording, "Lock this clip"))
        let stopped = CarPlayScreens.dashcam(dashcamInput(recording: false))
        XCTAssertNotNil(row(stopped, "Record"))
        XCTAssertNil(row(stopped, "Mic on"), "no mic row until the camera reports one")
    }

    /// Live view is still pictures, and only while parked on the camera's Wi‑Fi.
    func testLiveViewOnlyWhileParkedOnTheCamera() {
        let parked = CarPlayScreens.dashcam(dashcamInput(parked: true))
        XCTAssertEqual(row(parked, "Live view")?.action, .push(.live))
        XCTAssertEqual(row(parked, "Live view")?.enabled, true)
        let driving = CarPlayScreens.dashcam(dashcamInput(parked: false))
        XCTAssertEqual(row(driving, "Live view")?.enabled, false)
        XCTAssertEqual(row(driving, "Live view")?.detail, "Only while parked")
        XCTAssertNil(row(CarPlayScreens.dashcam(dashcamInput(onCamera: false, recording: nil)), "Live view"))
    }

    func testLiveScreenOffersTheOtherLens() {
        let s = CarPlayScreens.live(status: "Live · Front", otherLens: "Rear", canSwitch: true)
        XCTAssertEqual(rows(s).first?.title, "Live · Front")
        XCTAssertEqual(row(s, "Switch to the rear camera")?.action, .dashcam(.switchLens))
        XCTAssertNil(row(CarPlayScreens.live(status: "Live", otherLens: "Rear", canSwitch: false), "Switch to the rear camera"))
    }

    func testClipsShowStatusThumbnailAndOpenTheClip() {
        let c = clip("c1", kind: "event", lens: "rear", phone: "local", thumb: true)
        let s = CarPlayScreens.dashcam(dashcamInput(clips: [c]))
        let r = rows(s).first { $0.id == "clip:c1" }!
        XCTAssertTrue(r.title.contains("Event"))
        XCTAssertTrue(r.title.contains("Rear"))
        XCTAssertEqual(r.detail, "On phone")
        XCTAssertEqual(r.clipThumbID, "c1")
        XCTAssertEqual(r.action, .push(.clip(id: "c1")))
        XCTAssertEqual(row(s, "Drives")?.action, .push(.drives))
        XCTAssertEqual(row(s, "Settings")?.action, .push(.dashcamSettings))
    }

    func testClipInfoActionsFollowWhereItIs() {
        let onCard = clip("a", onCamera: true, phone: "none")
        XCTAssertEqual(CarPlayScreens.clip(onCard, topMps: nil).actions.map(\.title), ["Download", "Delete…"])
        let failed = clip("b", phone: "local", destinations: ["drive": ["state": "failed", "error": "quota"]])
        XCTAssertEqual(CarPlayScreens.clip(failed, topMps: nil).actions.map(\.title), ["Retry upload", "Delete…"])
        let info = CarPlayScreens.clip(failed, topMps: 30)
        XCTAssertTrue(info.items.contains(CarPlayInfoItem(title: "Top speed", detail: "67 mph")))
        XCTAssertTrue(info.items.contains { $0.title == "drive" && $0.detail.contains("quota") })
    }

    func testDeleteOffersOnlyThePlacesTheClipIs() {
        let c = clip("a", onCamera: true, phone: "local")
        XCTAssertEqual(CarPlayScreens.clipDeleteOptions(c).map(\.title), ["From this phone", "From the dashcam", "Everywhere"])
    }

    func testDrivesHaveASummaryAndADayPerSection() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let d = DashcamDrive(json: ["id": "d", "start": ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                                    "distance_m": 16093.44, "duration_s": 900, "max_mps": 26.8])!
        let s = CarPlayScreens.drives([d], now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Last 7 days", "Today"])
        XCTAssertEqual(rows(s)[0].detail, "1 drive · 10 mi · top 60 mph")
        XCTAssertEqual(rows(s)[1].action, .none)
    }

    func testSettingsListTheSwitchesRulesAndCamera() {
        var rules = DashcamRules(); rules.upload = true
        let mic = DashcamSettingItem(name: "mic", value: "1", options: [.init(code: "1", label: "On"), .init(code: "0", label: "Off")])
        let s = CarPlayScreens.dashcamSettings(CarPlayDashcamSettingsInput(
            liveActivity: true, autoSync: false, rules: rules, rulesLoaded: true, onCamera: true,
            cameraItems: [mic], sd: DashcamSDInfo(ok: true, totalBytes: 64_000_000_000, freeBytes: 12_300_000_000)))
        XCTAssertEqual(row(s, "Lock Screen progress")?.detail, "On")
        XCTAssertEqual(row(s, "Lock Screen progress")?.action, .dashcam(.liveActivity(false)))
        XCTAssertEqual(row(s, "Auto download")?.action, .dashcam(.autoSync(true)))
        XCTAssertEqual(row(s, "Normal footage")?.action, .dashcam(.chooseRule(.normal)))
        XCTAssertEqual(row(s, "Over mobile data")?.action, .dashcam(.chooseRule(.uploadData)))
        XCTAssertEqual(row(s, "Microphone")?.detail, "On")
        XCTAssertEqual(row(s, "Microphone")?.action, .dashcam(.chooseSetting("mic")))
        XCTAssertEqual(row(s, "Free")?.detail, "12.3 of 64.0 GB")
    }

    func testRuleChoicesTickTheCurrentValueAndApply() {
        var rules = DashcamRules(); rules.normal = .front
        let options = CarPlayScreens.ruleOptions(.normal, rules)
        XCTAssertEqual(options.map(\.title), DashcamRules.Normal.allCases.map(\.label))
        XCTAssertEqual(options.filter(\.checked).map(\.title), [DashcamRules.Normal.front.label])
        XCTAssertEqual(CarPlayScreens.applyRule(.normal, choice: 2, to: rules).normal, .all)
        XCTAssertEqual(CarPlayScreens.applyRule(.phoneCap, choice: 0, to: rules).phoneCapGB, CarPlayScreens.phoneCapChoices[0])
    }

    // MARK: Depth

    func testNothingPushesPastDepthThree() {
        for screen in [CarPlayScreen.dashcam, .device(id: "d")] {
            XCTAssertEqual(screen.depth, 2, "\(screen)")
        }
        for screen in [CarPlayScreen.clip(id: "c"), .drives, .dashcamSettings, .live] {
            XCTAssertEqual(screen.depth, 3, "\(screen)")
        }
        // Depth-3 screens built from lists never push.
        XCTAssertTrue(pushedScreens(CarPlayScreens.drives([], now: Date(), calendar: .current)).isEmpty)
        XCTAssertTrue(pushedScreens(CarPlayScreens.live(status: "Live", otherLens: "Rear", canSwitch: true)).isEmpty)
        XCTAssertTrue(pushedScreens(CarPlayScreens.dashcamSettings(CarPlayDashcamSettingsInput(
            liveActivity: false, autoSync: true, rules: DashcamRules(), rulesLoaded: true, onCamera: false,
            cameraItems: [], sd: nil))).isEmpty)
        // Depth-2 screens push only to depth 3.
        let pushedFromDashcam = pushedScreens(CarPlayScreens.dashcam(dashcamInput(clips: [clip("c")])))
        XCTAssertTrue(pushedFromDashcam.allSatisfy { $0.depth == 3 }, "\(pushedFromDashcam)")
    }

    // MARK: Review fixes

    /// Popping to the root (a model pick) drops every screen under it, not just the top one.
    func testStackKeepsOnlyTheScreensStillShowing() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        let entries = [("providers", a), ("models", b)]
        XCTAssertEqual(CarPlayStack.kept(entries, template: { $0.1 }, visible: [c]).map(\.0), [])
        XCTAssertEqual(CarPlayStack.kept(entries, template: { $0.1 }, visible: [c, a]).map(\.0), ["providers"])
    }

    /// Store changes that don't change what a screen shows don't rebuild it.
    func testUnchangedSectionsAreNotRebuilt() {
        var cache = CarPlaySectionsCache()
        let key = ObjectIdentifier(NSObject.self)
        let sections = CarPlayScreens.notPaired
        XCTAssertTrue(cache.changed(key, sections))
        XCTAssertFalse(cache.changed(key, sections))
        XCTAssertTrue(cache.changed(key, CarPlayScreens.wearablesTab([])))
    }

    func testLoadFailuresSaySoInsteadOfLookingEmpty() {
        XCTAssertEqual(rows(CarPlayScreens.drives([], error: "500")).map(\.title), ["Couldn't load drives"])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
