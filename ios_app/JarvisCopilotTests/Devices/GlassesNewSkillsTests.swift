import XCTest
@testable import JarvisCopilot

/// Glasses features that used to live only on their own screens — AI Notes, live
/// translation, live captions, Talk and "Use Jarvis for Glasses AI" — as tools.
@MainActor
final class GlassesNewSkillsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var fake: FakeScreenControls!
    private var device: InmoGo3Device!

    override func setUp() {
        super.setUp()
        suite = "glasses-new-skills-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        fake = FakeScreenControls()
        device = InmoGo3Device(identity: "inmo-go3-fixture", defaults: defaults)
        device.screenControls = fake
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private static let names = ["glasses_notes", "glasses_translate", "glasses_captions", "glasses_talk", "glasses_jarvis_ai"]

    func testTheNewToolsAreOfferedToJarvisWithOneSentenceDescriptions() throws {
        for name in Self.names {
            let capability = try XCTUnwrap(device.capabilities.first { $0.name == name }, name)
            XCTAssertTrue(capability.description.hasSuffix("."), name)
            XCTAssertFalse(capability.description.dropLast().contains(". "), "\(name): one sentence")
        }
    }

    func testNotesOffersTheScreensThreeActions() throws {
        let schema = try XCTUnwrap(device.capabilities.first { $0.name == "glasses_notes" }).inputSchema
        let action = try XCTUnwrap((schema["properties"] as? [String: [String: Any]])?["action"])
        XCTAssertEqual(action["enum"] as? [String], ["start", "stop", "summarise"])
        XCTAssertEqual(schema["required"] as? [String], ["action"])
    }

    func testTranslateOffersTheScreensLanguages() throws {
        let schema = try XCTUnwrap(device.capabilities.first { $0.name == "glasses_translate" }).inputSchema
        let props = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let codes = GlassesTranslateView.languages.map(\.code)
        XCTAssertEqual(props["from"]?["enum"] as? [String], codes)
        XCTAssertEqual(props["to"]?["enum"] as? [String], codes)
        XCTAssertEqual(props["on"]?["type"] as? String, "boolean")
        XCTAssertEqual(schema["required"] as? [String], ["on"])
    }

    /// Notes, translation and Talk connect on their own; captions and the AI switch need no link.
    func testTheyRunWhileTheGlassesAreDisconnected() async throws {
        XCTAssertFalse(device.isConnected)
        _ = try await device.invoke("glasses_notes", args: ["action": "start"])
        _ = try await device.invoke("glasses_notes", args: ["action": "stop"])
        _ = try await device.invoke("glasses_notes", args: ["action": "summarise"])
        _ = try await device.invoke("glasses_translate", args: ["on": true, "from": "fr", "to": "en"])
        _ = try await device.invoke("glasses_translate", args: ["on": false])
        _ = try await device.invoke("glasses_captions", args: ["on": true])
        _ = try await device.invoke("glasses_talk", args: [:])
        _ = try await device.invoke("glasses_jarvis_ai", args: ["on": false])
        XCTAssertEqual(fake.calls, ["note start", "note stop", "note summarise", "translate on fr en",
                                    "translate off - -", "captions on", "talk", "jarvisAI off"])
    }

    func testTranslateWithoutLanguagesKeepsTheLastPair() async throws {
        _ = try await device.invoke("glasses_translate", args: ["on": true])
        XCTAssertEqual(fake.calls, ["translate on - -"])
    }

    func testBadArgumentsNeverReachTheScreens() async {
        let bad: [(String, [String: Any])] = [
            ("glasses_notes", ["action": "delete"]),
            ("glasses_notes", [:]),
            ("glasses_translate", [:]),
            ("glasses_translate", ["on": "yes"]),
            ("glasses_translate", ["on": true, "from": "klingon"]),
            ("glasses_translate", ["on": true, "from": "en", "to": "en"]),
            ("glasses_captions", ["on": 1]),
            ("glasses_jarvis_ai", [:]),
        ]
        for (name, args) in bad {
            do {
                _ = try await device.invoke(name, args: args)
                XCTFail("\(name) \(args) should be refused")
            } catch DeviceError.badArgument { } catch { XCTFail("\(name): \(error)") }
        }
        XCTAssertEqual(fake.calls, [])
    }

    /// The live captions control flips the same switch as Glasses → Live captions → Show on glasses.
    func testLiveCaptionsUsesTheCaptionsScreensSwitch() {
        let bridge = LiveLensBridge(source: { IdleSource() }, defaults: defaults, glassesReady: { false })
        let controls = LiveGlassesScreenControls(captions: { bridge })
        let on = controls.captions(on: true)
        XCTAssertTrue(bridge.enabled)
        XCTAssertTrue(defaults.bool(forKey: LiveLensBridge.showKey))
        XCTAssertEqual(on["status"] as? String, LiveCaptionsSettingsView.describe(bridge.status))
        _ = controls.captions(on: false)
        XCTAssertFalse(bridge.enabled)
    }

    /// The translation tool's languages land where the Translate screen's pickers keep them.
    func testTranslatorLanguagesAreTheScreensSettings() {
        let translator = GlassesTranslator(defaults: defaults)
        translator.setLanguages(source: "fr", target: "de")
        XCTAssertEqual(translator.source, "fr")
        XCTAssertEqual(translator.target, "de")
        translator.setLanguages(source: nil, target: "ja")
        XCTAssertEqual(translator.source, "fr")
        XCTAssertEqual(translator.target, "ja")
    }
}

@MainActor
private final class FakeScreenControls: GlassesScreenControls {
    var calls: [String] = []
    func note(_ action: String) async throws -> [String: Any] { calls.append("note \(action)"); return [:] }
    func translate(on: Bool, from: String?, to: String?) async throws -> [String: Any] {
        calls.append("translate \(on ? "on" : "off") \(from ?? "-") \(to ?? "-")"); return [:]
    }
    func captions(on: Bool) -> [String: Any] { calls.append("captions \(on ? "on" : "off")"); return [:] }
    func talk() async throws -> [String: Any] { calls.append("talk"); return [:] }
    func jarvisAI(on: Bool) async -> [String: Any] { calls.append("jarvisAI \(on ? "on" : "off")"); return [:] }
}

@MainActor
private final class IdleSource: LiveCaptionSource {
    var isCapturing: Bool { false }
    func captionSnapshot() -> LiveCaptionSnapshot { LiveCaptionSnapshot(partial: "", segments: []) }
    func startCapture() async -> Bool { false }
    func runFactCheck() async -> (title: String, text: String)? { nil }
}
