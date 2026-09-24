import XCTest
@testable import JarvisCopilot

/// The phone's view of `/api/speech/*`: which engine hears each surface, and
/// every Soniox option. Nothing is stored on the phone, and the Soniox key only
/// ever goes up.
@MainActor
final class SpeechEngineAPITests: XCTestCase {

    private let server: [String: Any] = [
        "config": [
            "surfaces": ["voice": "soniox", "live": "edge", "upload": "local"],
            "soniox": ["model": "stt-rt-v5", "language_hints": ["en", "es"], "speaker_labels": false,
                       "language_id": true, "custom_words": ["Jarvis"], "endpoint_latency_level": 3,
                       "endpoint_sensitivity": 0.5, "max_endpoint_delay_ms": 1500, "live_quiet_close_s": 120],
        ],
        "engines": [
            ["name": "local", "label": "Current flow (this server)", "streams": false, "available": true, "reason": ""],
            ["name": "soniox", "label": "Soniox", "streams": true, "available": false, "reason": "no SONIOX_API_KEY"],
        ],
        "languages": [["code": "en", "name": "English"], ["code": "es", "name": "Spanish"]],
        "soniox_key": ["set": true, "hint": "••••1a2b"],
        "usage": ["today_s": 600, "month_s": 7200, "est_usd": 0.24],
    ]

    func testParsesEverythingTheServerSends() {
        let s = SpeechSettings.from(server)
        XCTAssertEqual([s.voice, s.live, s.upload], ["soniox", "edge", "local"])
        XCTAssertEqual(s.soniox.languageHints, ["en", "es"])
        XCTAssertFalse(s.soniox.speakerLabels)
        XCTAssertTrue(s.soniox.languageID)
        XCTAssertEqual(s.soniox.customWords, ["Jarvis"])
        XCTAssertEqual(s.soniox.endpointLatencyLevel, 3)
        XCTAssertEqual(s.soniox.endpointSensitivity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.soniox.maxEndpointDelayMs, 1500)
        XCTAssertEqual(s.soniox.liveQuietCloseS, 120)
        XCTAssertEqual(s.engines.map(\.name), ["local", "soniox"])
        XCTAssertEqual(s.engine("soniox")?.reason, "no SONIOX_API_KEY")
        XCTAssertEqual(s.streamingEngines.map(\.name), ["soniox"])
        XCTAssertEqual(s.languages.map(\.code), ["en", "es"])
        XCTAssertTrue(s.keySet)
        XCTAssertEqual(s.keyHint, "••••1a2b")
        XCTAssertEqual(s.monthSeconds, 7200)
        XCTAssertEqual(s.monthUSD, 0.24, accuracy: 0.0001)
    }

    func testAMissingSectionKeepsTheDefaults() {
        let s = SpeechSettings.from([:])
        XCTAssertEqual([s.voice, s.live, s.upload], ["local", "edge", "local"])
        XCTAssertTrue(s.soniox.speakerLabels)
        XCTAssertFalse(s.keySet)
    }

    func testNamesForThePickers() {
        let s = SpeechSettings.from(server)
        XCTAssertEqual(s.label(for: "edge"), "On this phone (Apple)")
        XCTAssertEqual(s.label(for: "soniox"), "Soniox")
        XCTAssertEqual(s.label(for: "nope"), "nope")
        XCTAssertEqual(s.languageName("es"), "Spanish")
    }

    func testLoadAndSaveASurfaceSendsOnlyThatSurface() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/speech/config", json: server)
        let store = SpeechEngineStore(api: SpeechEngineAPI(api: api))
        await store.load()
        XCTAssertTrue(store.loaded)
        XCTAssertEqual(store.settings.voice, "soniox")

        await store.setSurface("live", to: "soniox")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(transport.lastBody() as NSDictionary, ["surfaces": ["live": "soniox"]] as NSDictionary)
    }

    func testAFailedSaveRollsBack() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: server)
        transport.enqueue(json: ["error": "soniox.speaker_labels must be true or false"], status: 400)
        let store = SpeechEngineStore(api: SpeechEngineAPI(api: api))
        await store.load()
        await store.setSoniox(\.speakerLabels, true, key: "speaker_labels")
        XCTAssertFalse(store.settings.soniox.speakerLabels, "the server refused, so the screen shows what it holds")
        XCTAssertFalse(store.error.isEmpty)
    }

    func testTheKeyGoesUpTrimmedAndIsNeverKept() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "soniox_key": ["set": true, "hint": "••••9z9z"]])
        transport.enqueue(json: server)  // the reload after a key change
        let store = SpeechEngineStore(api: SpeechEngineAPI(api: api))
        let saved = await store.saveKey("  sk-secret-9z9z \n")
        XCTAssertTrue(saved)
        let sent = transport.requests.first { $0.url?.path.contains("soniox-key") == true }
        let body = sent?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(body?["api_key"] as? String, "sk-secret-9z9z")
        let mirror = String(describing: store.settings)
        XCTAssertFalse(mirror.contains("sk-secret"), "the key must not live on the phone after it is sent")
    }
}
