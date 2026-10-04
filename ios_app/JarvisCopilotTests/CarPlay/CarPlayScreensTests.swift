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
                              mic: DashcamMic? = nil, canReconnect: Bool = true, passActive: Bool = false) -> CarPlayDashcamInput {
        CarPlayDashcamInput(onCamera: onCamera, phaseLabel: "Up to date", recording: recording, sdFreeBytes: 12_300_000_000,
                            subtitle: "Synced 2 min ago", downloading: nil, uploading: nil, cloudBackupOn: true,
                            uploadNote: nil, passActive: passActive, mic: mic, canReconnect: canReconnect,
                            filter: .all, clips: clips, canLoadMore: false, libraryError: nil)
    }

    // MARK: Not paired

    func testNotPairedIsOneReadableRow() {
        let r = rows(CarPlayScreens.notPaired)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].title, "Pair Jarvis on your iPhone")
        XCTAssertEqual(r[0].action, .none)
    }

    // MARK: Jarvis tab + pickers

    func testJarvisTabTalksAndOpensThePickers() {
        let s = CarPlayScreens.jarvisTab(CarPlayVoiceSummary(stateText: "Ready", chatLabel: "Voice",
                                                             harnessLabel: "⚡ Fast + Claude", modelLabel: "Auto"))
        let talk = rows(s).first!
        XCTAssertEqual(talk.title, "Talk to Jarvis")
        XCTAssertTrue(talk.orb)
        XCTAssertEqual(talk.action, .startVoice)
        XCTAssertEqual(row(s, "Chat")?.detail, "Voice")
        XCTAssertEqual(row(s, "Chat")?.action, .push(.voiceChats))
        XCTAssertEqual(row(s, "Harness")?.detail, "⚡ Fast + Claude")
        XCTAssertEqual(row(s, "Harness")?.action, .push(.harnesses))
        XCTAssertEqual(row(s, "Model")?.action, .push(.modelProviders))
    }

    func testHarnessListTicksTheCurrentOneAndOffersSingleModel() {
        let s = CarPlayScreens.harnesses([("fast-claude", "⚡ Fast + Claude"), ("router", "Router"), ("single", "Single")],
                                         current: "router")
        XCTAssertEqual(rows(s).map(\.title), ["⚡ Fast + Claude", "Router", "Single model"])
        XCTAssertEqual(row(s, "Router")?.checked, true)
        XCTAssertEqual(row(s, "Single model")?.action, .selectHarness("single"))
    }

    func testProvidersStartWithAuto() {
        let s = CarPlayScreens.modelProviders(["Claude Code", "Ollama"], selectedProvider: nil)
        XCTAssertEqual(rows(s).map(\.title), ["Auto", "Claude Code", "Ollama"])
        XCTAssertEqual(rows(s)[0].checked, true)
        XCTAssertEqual(rows(s)[0].action, .selectModel(id: nil, provider: nil))
        XCTAssertEqual(row(s, "Ollama")?.action, .push(.models(provider: "Ollama")))
    }

    func testModelsSelectByCanonicalProviderID() {
        let m = ChatModel(id: "gemma4:31b", label: "Gemma 4 31B", provider: "Ollama Cloud", providerID: "ollama-cloud")
        let s = CarPlayScreens.models([m], selectedID: "gemma4:31b")
        XCTAssertEqual(rows(s)[0].checked, true)
        XCTAssertEqual(rows(s)[0].action, .selectModel(id: "gemma4:31b", provider: "ollama-cloud"))
    }

    func testVoiceChatsOfferNewDefaultAndRecent() {
        let sessions = [ChatSessionSummary(id: "a", title: "Groceries", updatedAt: 1_790_000_000)]
        let s = CarPlayScreens.voiceChats(sessions, target: .session(id: "a", title: "Groceries"))
        XCTAssertEqual(rows(s).map(\.title), ["New chat", "Voice", "Groceries"])
        XCTAssertEqual(row(s, "Groceries")?.checked, true)
        XCTAssertEqual(row(s, "Voice")?.action, .selectVoiceChat(id: nil, title: "Voice"))
        XCTAssertEqual(row(s, "New chat")?.action, .newVoiceChat)
    }

    // MARK: Chats

    func testChatsAreGroupedAndOpenTheChat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sessions = [ChatSessionSummary(id: "p", title: "Pinned", updatedAt: 1_000, pinned: true),
                        ChatSessionSummary(id: "t", title: "", updatedAt: Int(now.timeIntervalSince1970) - 60)]
        let s = CarPlayScreens.chats(sessions, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Pinned", "Today"])
        XCTAssertEqual(row(s, "New chat")?.action, .push(.chat(id: "t", title: "New chat")))
    }

    func testChatStartsWithContinueByVoiceThenMessagesOldestFirst() {
        let msgs = [ChatMessage.user("What's on my list?"),
                    ChatMessage(role: .assistant, blocks: [.text(TextBlock(text: "Milk and eggs."))]),
                    ChatMessage(role: .assistant, blocks: [])]           // a tool-only turn: no text, no row
        let s = CarPlayScreens.chat(id: "c1", title: "Groceries", messages: msgs)
        let r = rows(s)
        XCTAssertEqual(r[0].title, "Continue by voice")
        XCTAssertEqual(r[0].action, .continueByVoice(id: "c1", title: "Groceries"))
        XCTAssertEqual(r.dropFirst().map(\.title), ["You", "Jarvis"])
        XCTAssertEqual(r[2].detail, "Milk and eggs.")
        XCTAssertEqual(r[2].action, .push(.message(title: "Jarvis", text: "Milk and eggs.")))
    }

    func testLongMessagesAreShortenedInTheListButWholeOnTheirScreen() {
        let long = String(repeating: "word ", count: 100)
        let s = CarPlayScreens.chat(id: "c", title: "t", messages: [.user(long)])
        let detail = rows(s)[1].detail ?? ""
        XCTAssertLessThanOrEqual(detail.count, 121)
        XCTAssertTrue(detail.hasSuffix("…"))
        XCTAssertEqual(rows(s)[1].action, .push(.message(title: "You", text: long.trimmingCharacters(in: .whitespacesAndNewlines))))
        XCTAssertEqual(CarPlayScreens.message(title: "You", text: "hi").items, [CarPlayInfoItem(title: "You", detail: "hi")])
    }

    // MARK: Devices

    func testDevicesListDashcamWearablesAndServer() {
        let ring = CarPlayWearable(id: "r1", kind: WearableKeepAlive.ring, name: "Ring", model: "R12", statusText: "Connected",
                                   connected: true, batteryPercent: 80, lastSeen: nil, rssi: nil)
        let server = Device(json: ["id": "m1", "online": false, "platform": "desktop", "label": "MacBook Pro"])
        let s = CarPlayScreens.devices(CarPlayDevicesInput(
            dashcam: CarPlayDashcamRow(setUp: true, name: "A4", status: "Up to date · Recording"),
            wearables: [ring], server: [server]))
        XCTAssertEqual(s.map(\.title), ["Dashcam", "Wearables", "Server devices"])
        XCTAssertEqual(row(s, "A4")?.action, .push(.dashcam))
        XCTAssertEqual(row(s, "Ring")?.detail, "Connected · 80%")
        XCTAssertEqual(row(s, "Ring")?.action, .push(.device(id: "r1")))
        XCTAssertEqual(row(s, "MacBook Pro")?.detail, "Offline")
    }

    func testDashcamNotSetUpSaysWhereToDoIt() {
        let s = CarPlayScreens.devices(CarPlayDevicesInput(
            dashcam: CarPlayDashcamRow(setUp: false, name: "Dashcam", status: ""), wearables: [], server: []))
        XCTAssertEqual(row(s, "Dashcam")?.detail, "Set up on your iPhone")
        XCTAssertEqual(row(s, "Dashcam")?.enabled, false)
    }

    func testNoDevicesAtAll() {
        let s = CarPlayScreens.devices(CarPlayDevicesInput(dashcam: nil, wearables: [], server: []))
        XCTAssertEqual(rows(s).map(\.title), ["No devices yet"])
    }

    func testWearableInfoOffersConnectOnlyWhenAway() {
        let away = CarPlayWearable(id: "b", kind: WearableKeepAlive.bottle, name: "Bottle", model: "S1 Pro",
                                   statusText: "Not found", connected: false, batteryPercent: nil, lastSeen: nil, rssi: nil)
        XCTAssertEqual(CarPlayScreens.device(away).actions.map(\.action), [.connectWearable("b")])
        var near = away; near.connected = true; near.statusText = "Connected"
        XCTAssertTrue(CarPlayScreens.device(near).actions.isEmpty)
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
        for screen in [CarPlayScreen.harnesses, .modelProviders, .voiceChats, .chat(id: "c", title: "t"), .dashcam,
                       .device(id: "d"), .serverDevice(id: "s")] {
            XCTAssertEqual(screen.depth, 2, "\(screen)")
        }
        for screen in [CarPlayScreen.models(provider: "p"), .message(title: "t", text: "x"), .clip(id: "c"), .drives,
                       .dashcamSettings] {
            XCTAssertEqual(screen.depth, 3, "\(screen)")
        }
        // Depth-3 screens built from lists never push.
        let m = ChatModel(id: "x", label: "X", provider: "P", providerID: "p")
        XCTAssertTrue(pushedScreens(CarPlayScreens.models([m], selectedID: nil)).isEmpty)
        XCTAssertTrue(pushedScreens(CarPlayScreens.drives([], now: Date(), calendar: .current)).isEmpty)
        XCTAssertTrue(pushedScreens(CarPlayScreens.dashcamSettings(CarPlayDashcamSettingsInput(
            liveActivity: false, autoSync: true, rules: DashcamRules(), rulesLoaded: true, onCamera: false,
            cameraItems: [], sd: nil))).isEmpty)
        // Depth-2 screens push only to depth 3.
        let pushedFromDashcam = pushedScreens(CarPlayScreens.dashcam(dashcamInput(clips: [clip("c")])))
        XCTAssertTrue(pushedFromDashcam.allSatisfy { $0.depth == 3 }, "\(pushedFromDashcam)")
    }
}
