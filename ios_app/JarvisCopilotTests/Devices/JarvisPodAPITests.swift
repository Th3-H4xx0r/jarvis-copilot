import XCTest
@testable import JarvisCopilot

/// The Jarvis Pod's QR code, server records, skill results, and what the app sends it.
@MainActor
final class JarvisPodAPITests: XCTestCase {

    func testSetupCodeParses() throws {
        let code = try XCTUnwrap(PodSetupCode.parse(
            "jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=Jarvis-64D5&pw=ABCDEFGHJKMN&id=240AC41264D5"))
        XCTAssertEqual(code.ssid, "Jarvis-64D5")
        XCTAssertEqual(code.passphrase, "ABCDEFGHJKMN")
        XCTAssertEqual(code.mac, "240ac41264d5")
        XCTAssertEqual(code.podName, "Jarvis Pod 64D5")
    }

    /// The chat and model the Pod talks to; empty fields are the voice defaults.
    func testVoiceChoiceParsesAndSendsItsFields() {
        let voice = JarvisPodVoice(json: ["session_id": "chat-1", "model": "gpt-5", "provider": "openai", "x": 1])
        XCTAssertEqual(voice, JarvisPodVoice(sessionID: "chat-1", model: "gpt-5", provider: "openai"))
        XCTAssertEqual(voice.body(podID: "pod1") as NSDictionary,
                       ["device_id": "pod1", "session_id": "chat-1", "model": "gpt-5", "provider": "openai"] as NSDictionary)
        XCTAssertEqual(JarvisPodVoice(json: [:]), JarvisPodVoice())
    }

    func testRecordingParsesServerEntry() throws {
        let rec = try XCTUnwrap(JarvisPodRecording(json: [
            "id": "1757900000123", "ts": 1_757_900_000.123, "duration_ms": 2400, "transcript": " turn on the lights ",
        ]))
        XCTAssertEqual(rec.transcript, "turn on the lights")
        XCTAssertEqual(rec.durationText, "0:02")
        XCTAssertEqual(rec.date.timeIntervalSince1970, 1_757_900_000.123, accuracy: 0.001)
        XCTAssertEqual(JarvisPodRecording(json: ["id": "1", "ts": 1, "duration_ms": 61_500, "transcript": ""])?.durationText, "1:02")
        XCTAssertNil(JarvisPodRecording(json: ["ts": 1]))
        XCTAssertFalse(rec.cleaned)
        XCTAssertEqual(JarvisPodRecording(json: ["id": "2", "ts": 1, "cleaned": true])?.cleaned, true)
        XCTAssertTrue(JarvisPodSettings(json: [:]).noiseCancel)
        XCTAssertFalse(JarvisPodSettings(json: ["noise_cancel": false]).noiseCancel)
    }

    func testSetupCodeRejectsOtherCodes() {
        XCTAssertNil(PodSetupCode.parse("jarviscopilot://pair?server=x&code=ABC-DEF"))
        XCTAssertNil(PodSetupCode.parse("jarviscopilot://device-setup?v=1&kind=toaster&ssid=A&pw=ABCDEFGH&id=240ac41264d5"))
        XCTAssertNil(PodSetupCode.parse("jarviscopilot://device-setup?v=2&kind=jarvis_pod&ssid=A&pw=ABCDEFGH&id=240ac41264d5"))
        XCTAssertNil(PodSetupCode.parse("jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=A&pw=short&id=240ac41264d5"))
        XCTAssertNil(PodSetupCode.parse("jarviscopilot://device-setup?v=1&kind=jarvis_pod&pw=ABCDEFGH&id=240ac41264d5"))
        XCTAssertNil(PodSetupCode.parse("https://example.com"))
    }

    func testOnlyPodsComeOutOfTheDeviceList() {
        let pods = JarvisPodDevice.from(devices: [
            ["id": "a", "name": "Jarvis Pod 64D5", "user_agent": "JarvisPod/2.5.0", "online": true,
             "bridge_connected": true, "paired_at": 1_757_880_000.5, "last_seen": 1_757_880_100],
            ["id": "b", "name": "iPhone", "user_agent": "JarvisCopilot/1.0 iOS", "bridge_connected": true],
            ["id": "c", "name": "ESP32 board", "user_agent": "JarvisEsp32/1"],
        ])
        XCTAssertEqual(pods.map(\.id), ["a"])
        XCTAssertTrue(pods[0].bridgeConnected)
        XCTAssertEqual(pods[0].pairedAt, Date(timeIntervalSince1970: 1_757_880_000.5))
        XCTAssertEqual(pods[0].lastSeen, Date(timeIntervalSince1970: 1_757_880_100))
    }

    func testStatusDecodes() {
        let s = JarvisPodStatus(json: [
            "battery": ["level": 83, "charging": true],
            "wifi": ["ssid": "Home", "rssi": -52, "ip": "10.0.0.7"],
            "link": "connected",
            "page": ["home": "weather", "home_title": "Weather", "shown": ""],
            "touch": true, "wake_word": false, "fw": "2.5.0-jarvis",
        ])
        XCTAssertEqual(s.battery, 83)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.rssi, -52)
        XCTAssertEqual(s.homeTitle, "Weather")
        XCTAssertFalse(s.wakeWord)
        XCTAssertNil(JarvisPodStatus(json: ["wifi": ["rssi": 0]]).rssi, "0 dBm is no reading")
    }

    func testSettingsAndHomesDecode() {
        let s = JarvisPodSettings(json: ["home": "clock", "brightness": 60, "volume": 70, "wake_word": true,
                                          "theme": ["accent": "#3ec7c7"], "timezone": "Europe/London",
                                          "tz_posix": "STD0DST,M3.5.0/1,M10.5.0", "clock_24h": true])
        XCTAssertEqual(s.home, "clock")
        XCTAssertEqual(s.accent, "#3EC7C7")
        XCTAssertTrue(s.clock24h)
        let homes = JarvisPodHome.list(["pages": [["id": "orb", "title": "Orb", "builtin": true],
                                                   ["id": "weather", "title": "Weather", "builtin": false]]])
        XCTAssertEqual(homes.map(\.id), ["orb", "weather"])
        XCTAssertFalse(homes[1].builtin)
    }

    func testThemeComesFromTheSingleSources() {
        XCTAssertEqual(JarvisPodLook.theme["accent"], JarvisPodLook.hex(JcAccent.hex))
        XCTAssertEqual(JarvisPodLook.theme["danger"], JarvisPodLook.hex(JcTheme.dangerHex))
        XCTAssertEqual(JarvisPodLook.hex(0x3EC7C7), "#3EC7C7")
    }

    func testPosixTimeZones() throws {
        let sept2026 = Date(timeIntervalSince1970: 1_789_300_000)  // 2026-09-13
        XCTAssertEqual(JarvisPodLook.posixTZ(try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")), now: sept2026),
                       "STD8DST,M3.2.0,M11.1.0")
        XCTAssertEqual(JarvisPodLook.posixTZ(try XCTUnwrap(TimeZone(identifier: "Europe/London")), now: sept2026),
                       "STD0DST,M3.5.0/1,M10.5.0")
        XCTAssertEqual(JarvisPodLook.posixTZ(try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata")), now: sept2026), "STD-5:30")
        XCTAssertEqual(JarvisPodLook.posixTZ(try XCTUnwrap(TimeZone(identifier: "UTC")), now: sept2026), "STD0")
    }

    func testSetupBodyCarriesEverythingThePodNeeds() throws {
        let data = PodSetupFlow.setupBody(ssid: "Home", password: "hunter22", server: "https://j.example.com",
                                           pairing: PodPairing(code: "ABC-DEF", cfID: "id", cfSecret: "secret"),
                                           timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")),
                                           now: Date(timeIntervalSince1970: 1_789_300_000))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((body["wifi"] as? [String: String])?["password"], "hunter22")
        XCTAssertEqual(body["code"] as? String, "ABC-DEF")
        XCTAssertEqual((body["cf_access"] as? [String: String])?["client_secret"], "secret")
        XCTAssertEqual(body["tz_posix"] as? String, "STD8DST,M3.2.0,M11.1.0")
        XCTAssertNotNil((body["theme"] as? [String: String])?["accent"])
    }
}
