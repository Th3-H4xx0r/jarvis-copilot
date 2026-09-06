import Foundation
import XCTest
@testable import JarvisCopilot

/// The identifier → human-text layer the redesigned Devices tab runs on: skill
/// titles, categories, the meta line and "which of these is this phone".
final class DevicesTextTests: XCTestCase {

    private func skill(_ name: String, title: String = "", description: String = "")
        -> DeviceSkill {
        DeviceSkill(json: ["name": name, "title": title, "description": description])
    }

    // MARK: Titles

    func testIdentifiersBecomeSentenceCaseTitles() {
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "open_url"), "Open URL")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "clipboard_read"), "Clipboard read")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "text_to_speech"), "Text to speech")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "read_healthkit"), "Read HealthKit")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "send_sms"), "Send SMS")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "add_calendar_event"),
                       "Add calendar event")
        // Not Title Case — that is the look this screen is getting away from.
        XCTAssertNotEqual(DevicesSkillText.title(forIdentifier: "add_calendar_event"),
                          "Add Calendar Event")
    }

    func testTitleHandlesDashesDotsAndEmptyNames() {
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "phone-control"), "Phone control")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "browser.open_url"),
                       "Browser open URL")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: ""), "")
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "___"), "___")
    }

    func testCatalogueTitleWinsAndSpellingSurvives() {
        XCTAssertEqual(DevicesSkillText.title(for: skill("open_url", title: "Open a link")),
                       "Open a link")
        XCTAssertEqual(DevicesSkillText.title(for: skill("open_url", title: "   ")), "Open URL")
        XCTAssertEqual(DevicesSkillText.title(for: skill("copy_text")), "Copy text")
        // A word the server already capitalised is left exactly as it came.
        XCTAssertEqual(DevicesSkillText.title(forIdentifier: "open_HomeKit"), "Open HomeKit")
    }

    // MARK: Categories

    func testEverySkillThisPhoneRegistersLandsInANamedCategory() {
        let expected: [String: String] = [
            "clipboard_read": "Clipboard", "clipboard_write": "Clipboard",
            "take_photo": "Camera & photos", "pick_photo": "Camera & photos",
            "record_audio": "Audio", "play_audio": "Audio",
            "text_to_speech": "Audio", "set_volume": "Audio", "adjust_volume": "Audio",
            "send_sms": "Calls & messages", "make_call": "Calls & messages",
            "read_contacts": "Calls & messages",
            "set_alarm": "Calendar & reminders",
            "add_calendar_event": "Calendar & reminders",
            "list_calendar_events": "Calendar & reminders",
            "get_location": "Location",
            "read_healthkit": "Health",
            "run_shortcut": "Shortcuts", "shortcuts_list": "Shortcuts",
            "create_shortcut": "Shortcuts",
            "notify": "Notifications",
            "open_url": "Apps & sharing", "open_app": "Apps & sharing",
            "share_text": "Apps & sharing", "share_image": "Apps & sharing",
            "device_info": "Device", "battery_level": "Device", "vibrate": "Device",
            "flashlight_on": "Device", "flashlight_off": "Device",
            "phone_control": "Device", "phone_capabilities": "Device",
        ]
        for (name, category) in expected {
            XCTAssertEqual(DevicesSkillText.category(forIdentifier: name), category,
                           "\(name) miscategorised")
        }
    }

    func testUnknownSkillsFallToOtherRatherThanDisappearing() {
        XCTAssertEqual(DevicesSkillText.category(forIdentifier: "frobnicate"), "Other")
        XCTAssertEqual(DevicesSkillText.category(forIdentifier: ""), "Other")
        XCTAssertEqual(DevicesSkillText.categoryOrder.last, DevicesSkillText.otherCategory)
    }

    // MARK: Grouping

    func testGroupsFollowCategoryOrderAndSortRowsByTheirVisibleName() {
        let groups = DevicesSkillText.groups([
            skill("frobnicate"),
            skill("open_url"),
            skill("clipboard_write"),
            skill("clipboard_read"),
            skill("notify"),
            skill("open_app"),
        ])
        XCTAssertEqual(groups.map(\.title),
                       ["Clipboard", "Notifications", "Apps & sharing", "Other"])
        XCTAssertEqual(groups[0].skills.map(\.name), ["clipboard_read", "clipboard_write"])
        XCTAssertEqual(groups[2].skills.map { DevicesSkillText.title(for: $0) },
                       ["Open app", "Open URL"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.skills.count }, 6, "no skill is dropped")
    }

    func testGroupingSortsByTheTitleTheUserSeesNotTheIdentifier() {
        // "zebra_mode" is titled "Alarm sound" by the catalogue, so it sorts first.
        let groups = DevicesSkillText.groups([
            skill("aardvark_alarm", title: "Zzz snooze"),
            skill("zebra_alarm", title: "Alarm sound"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].skills.map(\.name), ["zebra_alarm", "aardvark_alarm"])
    }

    func testEmptySkillsProduceNoGroups() {
        XCTAssertTrue(DevicesSkillText.groups([]).isEmpty)
    }

    func testGrantedSummaryPluralises() {
        XCTAssertEqual(DevicesSkillText.grantedSummary(0), "No skills granted")
        XCTAssertEqual(DevicesSkillText.grantedSummary(1), "1 skill granted")
        XCTAssertEqual(DevicesSkillText.grantedSummary(31), "31 skills granted")
    }

    // MARK: Kind and meta line

    func testKindLabelSaysWhatTheGlyphShows() {
        func label(platform: String, name: String) -> String {
            DevicesKind.label(for: Device(json: ["id": "x", "platform": platform,
                                                 "label": name]))
        }
        XCTAssertEqual(label(platform: "mobile-ios", name: "Pranav's iPhone"), "iPhone")
        XCTAssertEqual(label(platform: "mobile-android", name: "Pixel"), "Android phone")
        XCTAssertEqual(label(platform: "browser", name: "Safari on iPad"), "iPad")
        XCTAssertEqual(label(platform: "browser", name: "Chrome Macintosh"), "Mac")
        XCTAssertEqual(label(platform: "browser", name: "Chrome"), "Browser")
        XCTAssertEqual(label(platform: "", name: "Apple Watch"), "Apple Watch")
        XCTAssertEqual(label(platform: "desktop", name: "windows box"), "Computer")
    }

    func testMetaLineIsOneMutedSentenceWithoutThePlatformSlug() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let phone = Device(json: ["id": "d1", "label": "Pranav's iPhone",
                                  "platform": "mobile-ios", "online": true,
                                  "last_seen": now.timeIntervalSince1970 - 660])
        XCTAssertEqual(DevicesKind.metaLine(for: phone, now: now), "iPhone · Online · 11m ago")

        let stale = Device(json: ["id": "d2", "label": "Studio desktop",
                                  "platform": "desktop", "online": false,
                                  "last_seen": now.timeIntervalSince1970 - 3 * 86_400])
        XCTAssertEqual(DevicesKind.metaLine(for: stale, now: now), "Computer · Offline · 3d ago")

        // A record with no timestamp still reads as a sentence.
        let fresh = Device(json: ["id": "d3", "label": "Chrome", "platform": "browser"])
        XCTAssertEqual(DevicesKind.metaLine(for: fresh, now: now), "Browser · Offline")
    }

    func testDetailLineCarriesTheRawPlatformAndPairingDate() {
        let device = Device(json: ["id": "d1", "platform": "mobile-ios",
                                   "created_at": "2026-04-02T18:20:00Z"])
        let detail = DevicesKind.detailLine(for: device)
        XCTAssertTrue(detail.hasPrefix("mobile-ios · paired 2026-04-0"), detail)
        XCTAssertEqual(DevicesKind.detailLine(for: Device(json: ["id": "d2"])), "")
    }

    // MARK: This device

    func testThisDeviceIsFoundByThePairingLabel() {
        let devices = [
            Device(json: ["id": "a", "label": "Chrome", "platform": "browser"]),
            Device(json: ["id": "b", "label": DevicesLocal.pairedLabel,
                          "platform": "mobile-ios"]),
            Device(json: ["id": "c", "label": "Old iPhone", "platform": "mobile-ios"]),
        ]
        XCTAssertEqual(DevicesLocal.thisDeviceID(in: devices), "b")
    }

    func testARenamedPhoneIsStillFoundWhenItIsTheOnlyIOSRecord() {
        let devices = [
            Device(json: ["id": "a", "label": "Chrome", "platform": "browser"]),
            Device(json: ["id": "b", "label": "Pranav's iPhone", "platform": "mobile-ios"]),
        ]
        XCTAssertEqual(DevicesLocal.thisDeviceID(in: devices), "b")
    }

    func testAmbiguousPhonesAreLeftUntagged() {
        let devices = [
            Device(json: ["id": "b", "label": "Pranav's iPhone", "platform": "mobile-ios"]),
            Device(json: ["id": "c", "label": "Spare iPhone", "platform": "mobile-ios"]),
        ]
        XCTAssertNil(DevicesLocal.thisDeviceID(in: devices))
        XCTAssertNil(DevicesLocal.thisDeviceID(in: []))
    }
}
