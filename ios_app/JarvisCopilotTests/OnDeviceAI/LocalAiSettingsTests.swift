import XCTest
@testable import JarvisCopilot

/// Case-for-case port of `mobile_client/test/local_ai_settings_test.dart`.
///
/// The two `androidStreamingStt` cases are deliberately absent: the Swift
/// `LocalAiSettings` drops that flag (it is an Android-only kill switch for a
/// recognizer pipe iOS doesn't have — see the doc comment on the Swift type).
@MainActor
final class LocalAiSettingsTests: XCTestCase {

    func testDefaultsAreOffAndServer() {
        let settings = LocalAiSettings(store: MemoryKeyValueStore())
        XCTAssertEqual(settings.tier, .off)
        XCTAssertFalse(settings.enabledForChat)
        XCTAssertFalse(settings.enabledForVoice)
        XCTAssertEqual(settings.activeLocalModelID, "apple-fm")
        XCTAssertEqual(settings.confidenceFloor, 0)
    }

    func testSaveThenLoadRoundTripsEveryField() {
        let kv = MemoryKeyValueStore()
        let a = LocalAiSettings(store: kv)
        a.tier = .fullLocalFirst
        a.chatEnabled = true
        a.voiceEnabled = true
        a.activeLocalModelID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        a.confidenceFloor = 0.7
        a.confirmLocalActions = false
        a.commandShortCircuit = false
        a.showBadge = false
        a.save()

        let b = LocalAiSettings(store: kv)
        b.load()
        XCTAssertEqual(b.tier, .fullLocalFirst)
        XCTAssertTrue(b.chatEnabled)
        XCTAssertTrue(b.voiceEnabled)
        XCTAssertEqual(b.activeLocalModelID, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(b.confidenceFloor, 0.7, accuracy: 0.0001)
        XCTAssertFalse(b.confirmLocalActions)
        XCTAssertFalse(b.commandShortCircuit)
        XCTAssertFalse(b.showBadge)
        XCTAssertTrue(b.enabledForChat)
    }

    func testEnabledForHonorsTierOffEvenWhenSurfaceEnabled() {
        let settings = LocalAiSettings(store: MemoryKeyValueStore())
        settings.tier = .off
        settings.chatEnabled = true
        XCTAssertFalse(settings.enabled(for: .chat))
    }

    // MARK: - The wire codec the Dart `LocalAiTierCodec` covered inline

    func testTierWireValuesRoundTrip() {
        XCTAssertEqual(LocalAiTier.off.wire, "off")
        XCTAssertEqual(LocalAiTier.routerCommands.wire, "router_commands")
        XCTAssertEqual(LocalAiTier.fullLocalFirst.wire, "full_local_first")
        XCTAssertEqual(LocalAiTier.parse("router_commands"), .routerCommands)
        XCTAssertEqual(LocalAiTier.parse("full_local_first"), .fullLocalFirst)
        XCTAssertEqual(LocalAiTier.parse("nonsense"), .off)
        XCTAssertEqual(LocalAiTier.parse(nil), .off)
    }

    /// The booleans default TRUE unless a "0" was explicitly stored — a fresh
    /// install must not silently ship with confirmations off.
    func testBooleanDefaultsSurviveAnEmptyStore() {
        let settings = LocalAiSettings(store: MemoryKeyValueStore())
        settings.load()
        XCTAssertTrue(settings.confirmLocalActions)
        XCTAssertTrue(settings.commandShortCircuit)
        XCTAssertTrue(settings.showBadge)
        XCTAssertEqual(settings.tier, .off)
    }
}
