import Foundation
@testable import JarvisCopilot

/// Fixtures for the Devices tab, shaped like the payloads the real server sends:
/// a phone that is this app, a browser session, a desktop that went away, the
/// thirty-odd skills a paired phone actually advertises, and a host that reports
/// metrics but no wiki.
///
/// Kept here rather than in `MoreUIBFixtures` because that file belongs to
/// another area; everything is prefixed so nothing collides module-wide.
enum DevicesFixtures {

    /// The identifiers the phone registers over the bridge (`PhoneSkills`,
    /// `SystemSkills`, `MediaSkills`, `DataSkills`, `IOSSkills`), with the
    /// one-line descriptions the catalogue carries.
    static let phoneSkillNames: [(String, String)] = [
        ("open_url", "Open a link in the browser"),
        ("open_app", "Launch an installed app"),
        ("notify", "Post a local notification"),
        ("clipboard_read", "Read the clipboard"),
        ("clipboard_write", "Put text on the clipboard"),
        ("share_text", "Open the share sheet with text"),
        ("share_image", "Share an image"),
        ("device_info", "Model, iOS version and locale"),
        ("battery_level", "Battery percentage and charging state"),
        ("vibrate", "Play a haptic"),
        ("flashlight_on", "Turn the torch on"),
        ("flashlight_off", "Turn the torch off"),
        ("make_call", "Dial a number"),
        ("send_sms", "Compose a text message"),
        ("read_contacts", "Look a contact up"),
        ("add_calendar_event", "Create a calendar event"),
        ("list_calendar_events", "Read the next events"),
        ("set_alarm", "Set an alarm"),
        ("read_healthkit", "Steps, sleep and workouts"),
        ("get_location", "Current coordinates"),
        ("take_photo", "Capture a photo"),
        ("pick_photo", "Choose from the library"),
        ("record_audio", "Record a voice clip"),
        ("play_audio", "Play a sound"),
        ("text_to_speech", "Speak a phrase aloud"),
        ("set_volume", "Set the media volume"),
        ("adjust_volume", "Nudge the volume"),
        ("run_shortcut", "Run a Shortcuts workflow"),
        ("shortcuts_list", "List the installed shortcuts"),
        ("create_shortcut", "Add a shortcut"),
        ("phone_control", "Airplane mode, Wi-Fi, brightness"),
        ("phone_capabilities", "What this phone can do"),
    ]

    static var skillCatalogue: [String: Any] {
        ["skills": phoneSkillNames.map { ["name": $0.0, "description": $0.1] }]
    }

    private static func grantedSkills(_ names: [String]) -> [[String: Any]] {
        let lookup = Dictionary(uniqueKeysWithValues: phoneSkillNames)
        return names.map { ["name": $0, "description": lookup[$0] ?? "", "allowed": true] }
    }

    /// Three records: this phone, a browser session, and a desktop last seen days
    /// ago. Timestamps are relative to `now` so the meta lines read the same on
    /// every run.
    static func devices(now: Date = Date()) -> [String: Any] {
        let epoch = now.timeIntervalSince1970
        return ["devices": [
            ["id": "d-phone",
             "label": DevicesLocal.pairedLabel,
             "platform": "mobile-ios",
             "online": true,
             "last_seen": epoch - 660,
             "created_at": "2026-04-02T18:20:00Z",
             "skills": grantedSkills(phoneSkillNames.map(\.0))],
            ["id": "d-browser",
             "label": "Chrome on Macintosh",
             "platform": "browser",
             "online": true,
             "last_seen": epoch - 90,
             "created_at": "2026-05-18T09:05:00Z",
             "skills": grantedSkills(["open_url", "clipboard_read", "clipboard_write",
                                      "notify", "share_text"])],
            ["id": "d-desk",
             "label": "Studio desktop",
             "platform": "desktop",
             "online": false,
             "last_seen": epoch - 3 * 86_400,
             "created_at": "2026-01-11T11:00:00Z",
             "skills": []],
        ]]
    }

    /// A host that reports all three metrics — the numbers from the screenshot
    /// that started this redesign.
    static let systemHealth: [String: Any] = [
        "status": "ok",
        "available": true,
        "checked_at": "2026-09-05T09:30:00Z",
        "cpu": ["percent": 30.8],
        "memory": ["percent": 28, "used_bytes": 4_500_000_000, "total_bytes": 16_000_000_000],
        "disk": ["percent": 69.4, "used_bytes": 69_400_000_000, "total_bytes": 100_000_000_000],
    ]

    /// Configured but not reachable — the "WIKI UNAVAILABLE" pill's data.
    static let wikiUnavailable: [String: Any] = [
        "available": false, "enabled": true, "status": "unavailable",
    ]

    @MainActor
    static func loadedStore(now: Date = Date()) async -> DevicesStore {
        let (api, transport) = JarvisAPI.mocked()
        // Substring routing, first match wins — the catalogue path also starts
        // with /api/devices.
        transport.route("/api/devices/skills", json: skillCatalogue)
        transport.route("/api/devices", json: devices(now: now))
        transport.route("/api/system/health", json: systemHealth)
        transport.route("/api/wiki/status", json: wikiUnavailable)
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        return store
    }

    @MainActor
    static func emptyStore() async -> DevicesStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["skills": []])
        transport.route("/api/devices", json: ["devices": []])
        transport.route("/api/system/health", json: systemHealth)
        transport.route("/api/wiki/status", json: wikiUnavailable)
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        return store
    }

    /// Every endpoint failing — the full-screen error branch.
    @MainActor
    static func failedStore() async -> DevicesStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["error": "off"], status: 500)
        transport.route("/api/devices", json: ["error": "Not paired with this server"],
                        status: 401)
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())
        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()
        return store
    }
}
