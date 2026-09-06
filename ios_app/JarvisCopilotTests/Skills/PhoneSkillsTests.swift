import XCTest
@testable import JarvisCopilot

/// Every skill driven against its mock boundary: success, permission-denied,
/// and bad args.
@MainActor
final class PhoneSkillsTests: XCTestCase {

    // MARK: open_url

    func testOpenURLLaunchesAndReportsTheResult() async throws {
        let urls = MockURLOpener()
        let result = try await SystemSkills.openURL(urls).run(["url": "https://x.com"])
        XCTAssertEqual(result["launched"] as? Bool, true)
        XCTAssertEqual(urls.opened.map(\.absoluteString), ["https://x.com"])
    }

    func testOpenURLReportsAFailedLaunch() async throws {
        let urls = MockURLOpener(openResult: false)
        let result = try await SystemSkills.openURL(urls).run(["url": "spotify://"])
        XCTAssertEqual(result["launched"] as? Bool, false)
    }

    func testOpenURLRejectsAMissingURL() async {
        await assertThrows(SkillError.badArgument("url required")) {
            try await SystemSkills.openURL(MockURLOpener()).run([:])
        }
    }

    func testOpenURLAcceptsWebMailAndDialSchemes() async throws {
        let urls = MockURLOpener()
        let skill = SystemSkills.openURL(urls)
        for text in ["https://x.com", "http://10.0.0.2:8080/a", "mailto:a@b.com", "tel:+15551234",
                     "spotify://album/1", "comgooglemaps://?q=home"] {
            let result = try await skill.run(["url": text])
            XCTAssertEqual(result["launched"] as? Bool, true, text)
        }
        XCTAssertEqual(urls.opened.count, 6)
    }

    /// `shortcuts://x-callback-url/run-shortcut` would run any Shortcut with no
    /// confirmation, straight past a `run_shortcut` the user switched off.
    func testOpenURLRefusesTheShortcutsAndCallbackSchemes() async throws {
        let urls = MockURLOpener()
        let skill = SystemSkills.openURL(urls)
        for text in ["shortcuts://x-callback-url/run-shortcut?name=Wipe",
                     "SHORTCUTS://run-shortcut?name=Wipe",
                     "jarviscopilot://shortcut-result/sc1?result=ok",
                     "file:///etc/passwd",
                     "javascript:alert(1)"] {
            do {
                let result = try await skill.run(["url": text])
                XCTFail("expected \(text) to be refused, got \(result)")
            } catch let error as SkillError {
                XCTAssertTrue((error.errorDescription ?? "").contains("not allowed"), text)
            }
        }
        XCTAssertTrue(urls.opened.isEmpty, "nothing may reach UIApplication.open")
    }

    func testOpenAppRefusesAnExplicitSchemeWithAPayload() async throws {
        let apps = MockAppOpener()
        let shortcuts = MockShortcutRunner()
        let result = try await SystemSkills.openApp(apps, shortcuts: shortcuts)
            .run(["scheme_url": "shortcuts://x-callback-url/run-shortcut?name=Wipe"])
        XCTAssertEqual(result["launched"] as? Bool, false)
        XCTAssertNotNil(result["error"] as? String)
        XCTAssertTrue(apps.requests.isEmpty, "the opener must never see it")
        XCTAssertTrue(shortcuts.calls.isEmpty, "and it must not fall through to the Shortcut")
    }

    /// The condensed-name fallback ("wells fargo" → "wellsfargo://") carries no
    /// payload, so it stays allowed — otherwise open_app only works for the
    /// couple of dozen apps in the table.
    func testOpenAppStillTriesTheCondensedNameScheme() async throws {
        let apps = MockAppOpener()
        let result = try await SystemSkills.openApp(apps, shortcuts: MockShortcutRunner())
            .run(["app": "wells fargo"])
        XCTAssertEqual(result["launched"] as? Bool, true)
        XCTAssertEqual(apps.requests.first?.appName, "wells fargo")
    }

    // MARK: open_app

    func testOpenAppUsesTheSchemeWhenItLaunches() async throws {
        let apps = MockAppOpener()
        let shortcuts = MockShortcutRunner()
        let result = try await SystemSkills.openApp(apps, shortcuts: shortcuts)
            .run(["app": "spotify"])
        XCTAssertEqual(result["launched"] as? Bool, true)
        XCTAssertEqual(apps.requests.first?.appName, "spotify")
        XCTAssertTrue(shortcuts.calls.isEmpty, "no need for the Shortcut fallback")
    }

    func testOpenAppFallsBackToTheOpenAppShortcut() async throws {
        let apps = MockAppOpener()
        apps.outcome = AppOpenOutcome(launched: false, error: "no scheme for \"chase\"")
        let shortcuts = MockShortcutRunner()
        let result = try await SystemSkills.openApp(apps, shortcuts: shortcuts).run(["app": "chase"])
        XCTAssertEqual(result["launched"] as? Bool, true)
        XCTAssertEqual(result["via"] as? String, "shortcut")
        // Fire-and-forget: "Open App" hands control to the target app, so no
        // x-callback may be requested.
        XCTAssertEqual(shortcuts.calls.first?.name, "JC Open App")
        XCTAssertEqual(shortcuts.calls.first?.awaitResult, false)
    }

    func testOpenAppReportsTheOriginalFailureWhenTheShortcutAlsoFails() async throws {
        let apps = MockAppOpener()
        apps.outcome = AppOpenOutcome(launched: false, error: "no scheme for \"chase\"")
        let shortcuts = MockShortcutRunner()
        shortcuts.outcome = ShortcutOutcome(ran: false, error: "no Shortcuts app")
        let result = try await SystemSkills.openApp(apps, shortcuts: shortcuts).run(["app": "chase"])
        XCTAssertEqual(result["launched"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "no scheme for \"chase\"")
    }

    // MARK: notify

    func testNotifyPostsALocalNotification() async throws {
        let notifier = MockNotifier()
        let result = try await SystemSkills.notify(notifier).run(["title": "Pasta", "body": "ready"])
        XCTAssertEqual(result["shown"] as? Bool, true)
        XCTAssertEqual(notifier.posted.first?.title, "Pasta")
        XCTAssertEqual(notifier.posted.first?.body, "ready")
        XCTAssertNil(notifier.posted.first?.at, "an immediate notification has no trigger")
    }

    func testNotifySurfacesADeniedPermission() async {
        await assertThrows(SkillError.permissionDenied("notifications")) {
            try await SystemSkills.notify(MockNotifier(granted: false)).run(["title": "hi"])
        }
    }

    func testNotifyRejectsAMissingTitle() async {
        await assertThrows(SkillError.badArgument("title required")) {
            try await SystemSkills.notify(MockNotifier()).run(["body": "orphan"])
        }
    }

    // MARK: clipboard

    func testClipboardReadReturnsTheText() async throws {
        let result = try await SystemSkills.clipboardRead(MockClipboard("copied")).run([:])
        XCTAssertEqual(result["text"] as? String, "copied")
    }

    func testClipboardReadReturnsEmptyStringWhenTheBoardIsEmpty() async throws {
        let result = try await SystemSkills.clipboardRead(MockClipboard(nil)).run([:])
        XCTAssertEqual(result["text"] as? String, "")
    }

    func testClipboardWriteReplacesTheContents() async throws {
        let clipboard = MockClipboard()
        let result = try await SystemSkills.clipboardWrite(clipboard).run(["text": "hello"])
        XCTAssertEqual(result["wrote"] as? Int, 5)
        XCTAssertEqual(clipboard.stored, "hello")
    }

    // MARK: share

    func testShareTextHandsAPayloadToThePresenter() async throws {
        let share = MockSharePresenter()
        let result = try await SystemSkills.shareText(share)
            .run(["text": "look", "subject": "Subj"])
        XCTAssertEqual(result["shared"] as? Bool, true)
        guard case .text(let text, let subject) = share.presented.first else {
            return XCTFail("expected a text payload")
        }
        XCTAssertEqual(text, "look")
        XCTAssertEqual(subject, "Subj")
    }

    func testShareTextRejectsEmptyText() async {
        await assertThrows(SkillError.badArgument("text required")) {
            try await SystemSkills.shareText(MockSharePresenter()).run(["text": ""])
        }
    }

    func testShareImageDecodesBase64AndStripsADataURIPrefix() async throws {
        let share = MockSharePresenter()
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let result = try await SystemSkills.shareImage(share)
            .run(["image_base64": "data:image/jpeg;base64,\(bytes.base64EncodedString())",
                  "caption": "hi"])
        XCTAssertEqual(result["bytes"] as? Int, 3)
        guard case .image(let data, let mime, let caption) = share.presented.first else {
            return XCTFail("expected an image payload")
        }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(caption, "hi")
    }

    func testShareImageRejectsGarbage() async {
        await assertThrows(SkillError.badArgument("image_base64 is not valid base64")) {
            try await SystemSkills.shareImage(MockSharePresenter())
                .run(["image_base64": "!!!!not base64!!!!"])
        }
    }

    // MARK: device_info / battery

    func testDeviceInfoIsPassedThrough() async throws {
        let result = try await SystemSkills.deviceInfo(MockDeviceInfo()).run([:])
        XCTAssertEqual(result["platform"] as? String, "ios")
        XCTAssertEqual(result["model"] as? String, "iPhone16,2")
    }

    func testBatteryLevelReportsLevelAndState() async throws {
        let result = try await SystemSkills.batteryLevel(MockBattery()).run([:])
        XCTAssertEqual(result["level"] as? Int, 77)
        XCTAssertEqual(result["state"] as? String, "discharging")
    }

    // MARK: vibrate

    func testVibrateBuzzesAndReportsThePulseCount() async throws {
        let haptics = MockHaptics()
        let result = try await SystemSkills.vibrate(haptics).run(["duration_ms": 300])
        XCTAssertEqual(result["vibrated"] as? Bool, true)
        XCTAssertEqual(result["duration_ms"] as? Int, 300)
        XCTAssertGreaterThan(haptics.buzzes, 0)
        XCTAssertEqual(result["pulses"] as? Int, haptics.buzzes)
    }

    func testVibrateHonoursAPattern() async throws {
        let haptics = MockHaptics()
        // Even indices are waits, odd ones are buzzes: two buzz segments here,
        // with the waits kept short so the test stays fast.
        let result = try await SystemSkills.vibrate(haptics).run(["pattern": [0, 100, 0, 100]])
        XCTAssertEqual(result["vibrated"] as? Bool, true)
        XCTAssertEqual(result["pattern"] as? [Int], [0, 100, 0, 100])
        XCTAssertEqual(haptics.buzzes, 2)
    }

    func testVibrateClampsOutOfRangeValues() async throws {
        let haptics = MockHaptics()
        let result = try await SystemSkills.vibrate(haptics)
            .run(["duration_ms": 1, "repeat": 99])
        XCTAssertEqual(result["repeat"] as? Int, 20)
    }

    func testVibrateReportsAMissingHapticEngine() async throws {
        let result = try await SystemSkills.vibrate(MockHaptics(available: false)).run([:])
        XCTAssertEqual(result["vibrated"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "no vibrator")
    }

    // MARK: flashlight

    func testFlashlightOnAndOff() async throws {
        let torch = MockTorch()
        let on = try await SystemSkills.flashlightOn(torch).run([:])
        XCTAssertEqual(on["on"] as? Bool, true)
        XCTAssertTrue(torch.isOn)
        let off = try await SystemSkills.flashlightOff(torch).run([:])
        XCTAssertEqual(off["on"] as? Bool, false)
        XCTAssertFalse(torch.isOn)
    }

    /// The Flutter skill *returned* the error rather than throwing, so the agent
    /// gets a usable answer instead of a tool failure — kept here.
    func testFlashlightReportsAMissingTorchWithoutThrowing() async throws {
        let torch = MockTorch()
        torch.error = SkillError.unavailable("device has no torch")
        let on = try await SystemSkills.flashlightOn(torch).run([:])
        XCTAssertEqual(on["on"] as? Bool, false)
        XCTAssertEqual(on["error"] as? String, "device has no torch")
        let off = try await SystemSkills.flashlightOff(torch).run([:])
        XCTAssertEqual(off["on"] as? Bool, true)
    }

    // MARK: make_call

    func testMakeCallOpensATelURL() async throws {
        let urls = MockURLOpener()
        let result = try await SystemSkills.makeCall(urls).run(["number": "+1 (510) 555-0100"])
        XCTAssertEqual(result["launched"] as? Bool, true)
        XCTAssertEqual(urls.opened.first?.absoluteString, "tel:+15105550100")
    }

    func testMakeCallRejectsAMissingNumber() async {
        await assertThrows(SkillError.badArgument("number required")) {
            try await SystemSkills.makeCall(MockURLOpener()).run([:])
        }
    }

    // MARK: get_location

    func testGetLocationReturnsAFix() async throws {
        let result = try await MediaSkills.getLocation(MockLocationFixer()).run([:])
        XCTAssertEqual(result["latitude"] as? Double, 37.33)
        XCTAssertEqual(result["longitude"] as? Double, -122.03)
        XCTAssertEqual(result["accuracy_m"] as? Double, 12)
        XCTAssertNotNil(result["ts"] as? String)
    }

    func testGetLocationSurfacesADeniedPermission() async {
        let locator = MockLocationFixer()
        locator.error = SkillError.permissionDenied("location")
        await assertThrows(SkillError.permissionDenied("location")) {
            try await MediaSkills.getLocation(locator).run([:])
        }
    }

    // MARK: photos

    func testTakePhotoReturnsBase64() async throws {
        let picker = MockPhotoPicker(image: CapturedImage(data: Data([1, 2, 3]), mime: "image/jpeg"))
        let result = try await MediaSkills.takePhoto(picker).run([:])
        XCTAssertEqual(result["bytes"] as? Int, 3)
        XCTAssertEqual(result["mime"] as? String, "image/jpeg")
        XCTAssertEqual(result["base64"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(picker.requested, [.camera])
    }

    func testPickPhotoReportsACancel() async throws {
        let picker = MockPhotoPicker(image: nil)
        let result = try await MediaSkills.pickPhoto(picker).run([:])
        XCTAssertEqual(result["cancelled"] as? Bool, true)
        XCTAssertEqual(picker.requested, [.library])
    }

    func testTheDefaultPickerIsAnHonestUnavailable() async {
        await assertThrows(SkillError.unavailable(
            "the camera/library picker is not wired up in this build yet")) {
            try await MediaSkills.takePhoto(UnavailablePhotoPicker()).run([:])
        }
    }

    // MARK: text_to_speech

    func testTextToSpeechSpeaksWithADefaultLocale() async throws {
        let speech = MockSpeech()
        let result = try await MediaSkills.textToSpeech(speech).run(["text": "hello"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(speech.spoken.first?.text, "hello")
        XCTAssertEqual(speech.spoken.first?.locale, "en-US")
    }

    func testTextToSpeechRejectsEmptyText() async {
        await assertThrows(SkillError.badArgument("text required")) {
            try await MediaSkills.textToSpeech(MockSpeech()).run([:])
        }
    }

    // MARK: record_audio

    func testRecordAudioReturnsAClip() async throws {
        let recorder = MockRecorder()
        let result = try await MediaSkills.recordAudio(recorder).run(["duration_s": 3])
        XCTAssertEqual(result["recorded"] as? Bool, true)
        XCTAssertEqual(result["duration_s"] as? Int, 3)
        XCTAssertEqual(recorder.requestedSeconds, 3)
    }

    func testRecordAudioClampsTheDuration() async throws {
        let recorder = MockRecorder()
        _ = try await MediaSkills.recordAudio(recorder).run(["duration_s": 900])
        XCTAssertEqual(recorder.requestedSeconds, 60)
    }

    func testRecordAudioReportsADeniedMicWithoutThrowing() async throws {
        let recorder = MockRecorder()
        recorder.error = SkillError.permissionDenied("microphone")
        let result = try await MediaSkills.recordAudio(recorder).run([:])
        XCTAssertEqual(result["recorded"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "microphone permission denied")
    }

    // MARK: play_audio

    func testPlayAudioPlaysBase64Bytes() async throws {
        let player = MockAudioPlayer()
        let result = try await MediaSkills.playAudio(player)
            .run(["audio_base64": Data([1, 2, 3, 4]).base64EncodedString()])
        XCTAssertEqual(result["played"] as? Bool, true)
        XCTAssertEqual(player.playedBytes, [4])
    }

    func testPlayAudioPlaysAURL() async throws {
        let player = MockAudioPlayer()
        let result = try await MediaSkills.playAudio(player).run(["url": "https://x.com/a.mp3"])
        XCTAssertEqual(result["played"] as? Bool, true)
        XCTAssertEqual(player.playedURLs.first?.absoluteString, "https://x.com/a.mp3")
    }

    func testPlayAudioNeedsSomethingToPlay() async throws {
        let result = try await MediaSkills.playAudio(MockAudioPlayer()).run([:])
        XCTAssertEqual(result["played"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "audio_base64 or url required")
    }

    /// The player fetches whatever URL it is handed, so `file://` would read the
    /// sandbox and `http://` would let the network choose what JARVIS says.
    func testPlayAudioOnlyFetchesOverHTTPS() async throws {
        let player = MockAudioPlayer()
        let skill = MediaSkills.playAudio(player)
        for text in ["http://x.com/a.mp3", "file:///etc/passwd", "ftp://x.com/a.mp3"] {
            let result = try await skill.run(["url": text])
            XCTAssertEqual(result["played"] as? Bool, false, text)
            XCTAssertEqual(result["error"] as? String, "url must be https://", text)
        }
        XCTAssertTrue(player.playedURLs.isEmpty)
    }

    // MARK: read_contacts

    func testReadContactsSearchesByNameAndNumber() async throws {
        let store = MockContactsStore(contacts: [
            ContactRecord(name: "Chahel Singh", phones: ["+1 510-378-0762"], emails: ["c@x.com"]),
            ContactRecord(name: "Mom", phones: ["(212) 555-0100"]),
        ])
        let skill = DataSkills.readContacts(store)

        let byName = try await skill.run(["query": "mom"])
        XCTAssertEqual(byName["total"] as? Int, 1)
        let first = try XCTUnwrap((byName["contacts"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["display_name"] as? String, "Mom")
        XCTAssertEqual(first["phones"] as? [String], ["(212) 555-0100"])

        // A number substring matches against the normalised digits.
        let byNumber = try await skill.run(["query": "5103780762"])
        XCTAssertEqual(byNumber["total"] as? Int, 1)

        // No query → everything, capped by limit.
        let all = try await skill.run([:])
        XCTAssertEqual(all["total"] as? Int, 2)
        let capped = try await skill.run(["limit": 1])
        XCTAssertEqual((capped["contacts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(capped["total"] as? Int, 2)
    }

    func testReadContactsReportsADeniedPermission() async throws {
        let result = try await DataSkills.readContacts(MockContactsStore(granted: false)).run([:])
        XCTAssertEqual(result["error"] as? String, "contacts permission denied")
    }

    /// A FAILED prompt is not a denial — reporting it as one sends the agent
    /// off telling the user to change a setting that is already correct.
    func testReadContactsSurfacesAFailedPermissionRequestAsItself() async {
        let store = MockContactsStore()
        store.accessError = SkillError.unavailable("contacts are restricted on this device")
        do {
            let result = try await DataSkills.readContacts(store).run([:])
            XCTFail("expected the request failure to propagate, got \(result)")
        } catch let error as SkillError {
            XCTAssertEqual(error, .unavailable("contacts are restricted on this device"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCalendarSurfacesAFailedPermissionRequestAsItself() async {
        let calendars = MockCalendar()
        calendars.accessError = SkillError.unavailable("EventKit is unavailable")
        do {
            let result = try await DataSkills.listCalendarEvents(calendars).run([
                "start_iso": "2026-09-05T09:00:00Z", "end_iso": "2026-09-05T10:00:00Z",
            ])
            XCTFail("expected the request failure to propagate, got \(result)")
        } catch let error as SkillError {
            XCTAssertEqual(error, .unavailable("EventKit is unavailable"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The schemas promise max 100 / 200 / 30; only the lower bound was clamped,
    /// so `limit: 100000` asked the device for everything.
    func testTheReadSkillsClampToTheirSchemaBounds() async throws {
        let contacts = MockContactsStore(contacts: (0..<150).map {
            ContactRecord(name: "P\($0)", phones: [])
        })
        let capped = try await DataSkills.readContacts(contacts).run(["limit": 100_000])
        XCTAssertEqual((capped["contacts"] as? [[String: Any]])?.count, 100)

        let calendars = MockCalendar(events: (0..<250).map {
            CalendarEventRecord(title: "E\($0)", notes: "", location: "",
                                start: nil, end: nil, allDay: false, calendar: "c")
        })
        let events = try await DataSkills.listCalendarEvents(calendars).run([
            "start_iso": "2026-09-05T09:00:00Z", "end_iso": "2026-09-06T09:00:00Z",
            "limit": 100_000,
        ])
        XCTAssertEqual((events["events"] as? [[String: Any]])?.count, 200)

        let health = MockHealthReader()
        _ = try await DataSkills.readHealth(health).run(["metric": "steps", "days": 9999])
        XCTAssertEqual(health.requested?.days, 30)
        _ = try await DataSkills.readHealth(health).run(["metric": "steps", "days": -5])
        XCTAssertEqual(health.requested?.days, 1)
    }

    // MARK: calendar

    func testAddCalendarEventSavesTheEvent() async throws {
        let calendars = MockCalendar()
        let result = try await DataSkills.addCalendarEvent(calendars).run([
            "title": "Standup",
            "start_iso": "2026-09-05T09:00:00Z",
            "end_iso": "2026-09-05T09:15:00Z",
            "location": "Zoom",
        ])
        XCTAssertEqual(result["saved"] as? Bool, true)
        XCTAssertEqual(result["event_id"] as? String, "event-1")
        XCTAssertEqual(calendars.added.first?.title, "Standup")
        XCTAssertEqual(calendars.added.first?.location, "Zoom")
        XCTAssertEqual(calendars.added.first?.allDay, false)
    }

    func testAddCalendarEventRejectsABadTimestamp() async {
        await assertThrows(SkillError.badArgument("start_iso must be an ISO-8601 timestamp")) {
            try await DataSkills.addCalendarEvent(MockCalendar())
                .run(["title": "x", "start_iso": "soonish", "end_iso": "2026-09-05T09:15:00Z"])
        }
    }

    func testAddCalendarEventReportsADeniedPermission() async throws {
        let result = try await DataSkills.addCalendarEvent(MockCalendar(granted: false)).run([
            "title": "x", "start_iso": "2026-09-05T09:00:00Z", "end_iso": "2026-09-05T09:15:00Z",
        ])
        XCTAssertEqual(result["error"] as? String, "calendar permission denied")
    }

    func testListCalendarEventsMapsToTheWireShape() async throws {
        let start = Date(timeIntervalSince1970: 1_757_055_600)
        let calendars = MockCalendar(events: [
            CalendarEventRecord(title: "Standup", notes: "daily", location: "Zoom",
                                start: start, end: start.addingTimeInterval(900),
                                allDay: false, calendar: "Work"),
        ])
        let result = try await DataSkills.listCalendarEvents(calendars).run([
            "start_iso": "2026-09-05T00:00:00Z", "end_iso": "2026-09-06T00:00:00Z",
        ])
        XCTAssertEqual(result["count"] as? Int, 1)
        let event = try XCTUnwrap((result["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["title"] as? String, "Standup")
        XCTAssertEqual(event["description"] as? String, "daily")
        XCTAssertEqual(event["calendar"] as? String, "Work")
        XCTAssertEqual(event["all_day"] as? Bool, false)
        XCTAssertFalse((event["start_iso"] as? String ?? "").isEmpty)
    }

    // MARK: set_alarm

    func testSetAlarmSchedulesARelativeAlarm() async throws {
        let notifier = MockNotifier()
        let now = Date(timeIntervalSince1970: 1_757_055_600)
        let result = try await DataSkills.setAlarm(notifier, now: { now })
            .run(["in_minutes": 10, "label": "Pasta"])
        XCTAssertEqual(result["scheduled"] as? Bool, true)
        let posted = try XCTUnwrap(notifier.posted.first)
        XCTAssertEqual(posted.title, "Pasta")
        XCTAssertEqual(posted.body, "JARVIS alarm")
        XCTAssertTrue(posted.sound)
        XCTAssertTrue(posted.timeSensitive)
        XCTAssertEqual(posted.at, now.addingTimeInterval(600))
    }

    func testSetAlarmRollsAPastClockTimeToTomorrow() async throws {
        let notifier = MockNotifier()
        let calendar = Calendar.current
        // 10:00 local today; ask for 09:00, which has passed.
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        _ = try await DataSkills.setAlarm(notifier, now: { now }).run(["hour": 9, "minute": 0])
        let at = try XCTUnwrap(notifier.posted.first?.at)
        XCTAssertGreaterThan(at, now)
        XCTAssertEqual(calendar.component(.hour, from: at), 9)
        XCTAssertEqual(calendar.dateComponents([.day], from: now, to: at).day, 0)
        XCTAssertTrue(at.timeIntervalSince(now) > 20 * 3600)
    }

    func testSetAlarmKeepsAFutureClockTimeToday() async throws {
        let notifier = MockNotifier()
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        _ = try await DataSkills.setAlarm(notifier, now: { now }).run(["hour": 9, "minute": 30])
        let at = try XCTUnwrap(notifier.posted.first?.at)
        XCTAssertEqual(calendar.component(.hour, from: at), 9)
        XCTAssertEqual(calendar.component(.minute, from: at), 30)
        XCTAssertEqual(at.timeIntervalSince(now), 90 * 60)
    }

    func testSetAlarmNeedsATime() async throws {
        let notifier = MockNotifier()
        let result = try await DataSkills.setAlarm(notifier).run(["label": "orphan"])
        XCTAssertEqual(result["scheduled"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "hour or in_minutes required")
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    // MARK: read_healthkit

    func testReadHealthMapsSamples() async throws {
        let health = MockHealthReader()
        let start = Date(timeIntervalSince1970: 1_757_055_600)
        health.samples = [HealthSample(value: 4231, unit: "count", start: start, end: start)]
        let result = try await DataSkills.readHealth(health).run(["metric": "steps", "days": 7])
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(health.requested?.metric, "steps")
        XCTAssertEqual(health.requested?.days, 7)
        let sample = try XCTUnwrap((result["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["value"] as? Double, 4231)
        XCTAssertEqual(sample["unit"] as? String, "count")
    }

    func testReadHealthReportsAnUnavailableStoreWithoutThrowing() async throws {
        let result = try await DataSkills.readHealth(UnavailableHealthReader())
            .run(["metric": "steps"])
        XCTAssertEqual(result["error"] as? String, "HealthKit is not enabled in this build")
    }

    func testReadHealthRejectsAMissingMetric() async {
        await assertThrows(SkillError.badArgument("metric required")) {
            try await DataSkills.readHealth(MockHealthReader()).run([:])
        }
    }

    // MARK: send_sms

    func testSendSMSReportsWhatTheUserDid() async throws {
        let composer = MockSmsComposer()
        let skill = IOSSkills.sendSMS(composer)

        let sent = try await skill.run(["number": "+15105550100", "message": "on my way"])
        XCTAssertEqual(sent["sent"] as? Bool, true)
        XCTAssertEqual(composer.composed.first?.number, "+15105550100")

        composer.outcome = .cancelled
        let cancelled = try await skill.run(["number": "1", "message": "x"])
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        XCTAssertEqual(cancelled["sent"] as? Bool, false)

        composer.outcome = .unavailable("SMS not available on this device")
        let unavailable = try await skill.run(["number": "1", "message": "x"])
        XCTAssertEqual(unavailable["shown"] as? Bool, false)
    }

    func testSendSMSRejectsMissingArgs() async {
        await assertThrows(SkillError.badArgument("number required")) {
            try await IOSSkills.sendSMS(MockSmsComposer()).run(["message": "hi"])
        }
        await assertThrows(SkillError.badArgument("message required")) {
            try await IOSSkills.sendSMS(MockSmsComposer()).run(["number": "1"])
        }
    }

    // MARK: run_shortcut

    func testRunShortcutReturnsTheOutput() async throws {
        let shortcuts = MockShortcutRunner()
        shortcuts.outcome = ShortcutOutcome(ran: true, launched: true, result: "73%")
        let result = try await IOSSkills.runShortcut(shortcuts)
            .run(["name": "JC Battery", "input": "x", "timeout_seconds": 15])
        XCTAssertEqual(result["ran"] as? Bool, true)
        XCTAssertEqual(result["result"] as? String, "73%")
        XCTAssertEqual(shortcuts.calls.first,
                       MockShortcutRunner.Call(name: "JC Battery", input: "x",
                                               timeoutSeconds: 15, awaitResult: true))
    }

    func testRunShortcutDefaultsTo90Seconds() async throws {
        let shortcuts = MockShortcutRunner()
        _ = try await IOSSkills.runShortcut(shortcuts).run(["name": "JC Focus"])
        XCTAssertEqual(shortcuts.calls.first?.timeoutSeconds, 90)
    }

    func testRunShortcutRejectsAMissingName() async {
        await assertThrows(SkillError.badArgument("name required")) {
            try await IOSSkills.runShortcut(MockShortcutRunner()).run([:])
        }
    }

    func testShortcutsListIsHonestAboutTheMissingAPI() async throws {
        let result = try await IOSSkills.shortcutsList(MockShortcutRunner()).run([:])
        XCTAssertEqual(result["names"] as? [String], [])
        XCTAssertNotNil(result["note"] as? String)
    }

    func testCreateShortcutOpensTheEditorOrTheImportPrompt() async throws {
        let shortcuts = MockShortcutRunner()
        let skill = IOSSkills.createShortcut(shortcuts)

        let created = try await skill.run([:])
        XCTAssertEqual(created["mode"] as? String, "create")
        XCTAssertEqual(created["opened"] as? Bool, true)

        let imported = try await skill.run(["import_url": "https://x.com/a.shortcut", "name": "JC X"])
        XCTAssertEqual(imported["mode"] as? String, "import")
        XCTAssertEqual(shortcuts.editorOpened.last?.importURL, "https://x.com/a.shortcut")
        XCTAssertEqual(shortcuts.editorOpened.last?.name, "JC X")

        shortcuts.editorResult = false
        let failed = try await skill.run([:])
        XCTAssertEqual(failed["opened"] as? Bool, false)
        XCTAssertNotNil(failed["error"] as? String)
    }

    // MARK: phone_control

    func testPhoneControlRunsThePerVerbShortcut() async throws {
        let shortcuts = MockShortcutRunner()
        let result = try await IOSSkills.phoneControl(shortcuts, contacts: MockContactsStore(), sms: MockSmsComposer())
            .run(["action": "brightness", "value": 0.3])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["shortcut"] as? String, "JC Brightness")
        XCTAssertEqual(result["value"] as? String, "30")
        XCTAssertEqual(shortcuts.calls.first?.awaitResult, true)
        XCTAssertEqual(shortcuts.calls.first?.timeoutSeconds, 30)
    }

    /// `send_message` used to run the "JC Send Message" Shortcut, which sends
    /// outright. It must go through the Messages composer instead — iOS then
    /// requires the user to tap Send, the same double gate `send_sms` has.
    func testPhoneControlSendMessageGoesThroughTheComposerNotAShortcut() async throws {
        let shortcuts = MockShortcutRunner()
        let sms = MockSmsComposer()
        let contacts = MockContactsStore(contacts: [
            ContactRecord(name: "Chahel Singh", phones: ["+1 510-378-0762"]),
        ])
        let result = try await IOSSkills.phoneControl(shortcuts, contacts: contacts, sms: sms)
            .run(["action": "send_message", "to": "Chahel", "message": "hi"])
        XCTAssertTrue(shortcuts.calls.isEmpty, "no silent Shortcut send")
        // The recipient NAME is still resolved against the address book first.
        XCTAssertEqual(sms.composed.first?.number, "+15103780762")
        XCTAssertEqual(sms.composed.first?.message, "hi")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["via"] as? String, "composer")
        XCTAssertEqual(result["shown"] as? Bool, true)
    }

    func testPhoneControlSendMessageReportsACancelledComposer() async throws {
        let sms = MockSmsComposer()
        sms.outcome = .cancelled
        let result = try await IOSSkills.phoneControl(MockShortcutRunner(),
                                                     contacts: MockContactsStore(), sms: sms)
            .run(["action": "send_message", "to": "+15105550100", "message": "hi"])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["cancelled"] as? Bool, true)
    }

    func testPhoneControlSendMessageNeedsARecipientAndABody() async throws {
        let sms = MockSmsComposer()
        let skill = IOSSkills.phoneControl(MockShortcutRunner(),
                                           contacts: MockContactsStore(), sms: sms)
        let noRecipient = try await skill.run(["action": "send_message", "message": "hi"])
        XCTAssertEqual(noRecipient["ok"] as? Bool, false)
        let noBody = try await skill.run(["action": "send_message", "to": "+15105550100"])
        XCTAssertEqual(noBody["ok"] as? Bool, false)
        XCTAssertTrue(sms.composed.isEmpty)
    }

    /// Belt and braces: even if the composer route were bypassed, there is no
    /// Shortcut left that could send silently.
    func testNoShortcutCanStillSendAMessage() {
        XCTAssertNil(PhoneCommand.verbShortcutNames["send_message"])
        XCTAssertNil(PhoneCommand.shortcut(for: ["action": "send_message",
                                                 "to": "Mom", "message": "hi"]))
    }

    func testPhoneControlRedirectsToNativeSkills() async throws {
        let shortcuts = MockShortcutRunner()
        let result = try await IOSSkills.phoneControl(shortcuts, contacts: MockContactsStore(), sms: MockSmsComposer())
            .run(["action": "open_app", "app": "Spotify"])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue((result["error"] as? String ?? "").contains("open_app"))
        XCTAssertTrue(shortcuts.calls.isEmpty, "a redirect must not bounce a Shortcut")
    }

    func testPhoneControlRejectsAnUnknownVerb() async throws {
        let result = try await IOSSkills.phoneControl(MockShortcutRunner(),
                                                     contacts: MockContactsStore(),
                                                     sms: MockSmsComposer())
            .run(["action": "make_coffee"])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue((result["error"] as? String ?? "").contains("make_coffee"))
    }

    func testPhoneControlSurfacesAMissingShortcut() async throws {
        let shortcuts = MockShortcutRunner()
        shortcuts.outcome = ShortcutOutcome(ran: false, error: "no shortcut")
        let result = try await IOSSkills.phoneControl(shortcuts, contacts: MockContactsStore(), sms: MockSmsComposer())
            .run(["action": "wifi", "value": 0])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue((result["error"] as? String ?? "").contains("JC WiFi"))
    }

    func testPhoneControlRequiresAnAction() async {
        await assertThrows(SkillError.badArgument("action required")) {
            try await IOSSkills.phoneControl(MockShortcutRunner(), contacts: MockContactsStore(),
                                             sms: MockSmsComposer())
                .run(["value": 1])
        }
    }

    func testPhoneCapabilitiesIsStatic() async throws {
        let result = try await IOSSkills.phoneCapabilities().run([:])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["verbs"] as? [String], PhoneCommand.verbOrder)
        XCTAssertEqual((result["shortcuts"] as? [String: String])?["brightness"], "JC Brightness")
    }

    // MARK: helper

    private func assertThrows(_ expected: SkillError,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> [String: Any]) async {
        do {
            let result = try await body()
            XCTFail("expected \(expected), got \(result)", file: file, line: line)
        } catch let error as SkillError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
