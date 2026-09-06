import Foundation
import XCTest
@testable import JarvisCopilot

/// Port of `test/background_keepalive_test.dart`.
///
/// The Dart file had two groups: six cases over the pure `computeKeepaliveArmed`
/// decision, and two over `BackgroundKeepalive.sync`'s coalescing (the platform
/// channel is only invoked when the armed state changes).
///
/// **The pure half ports directly** (`BackgroundKeepalive.shouldRun`), with the
/// two Dart inputs this port deliberately does not have folded into the
/// assertions below — see `shouldRun`'s own note for why `background` and
/// `voiceActive` are gone.
///
/// **The coalescing half is asserted structurally, not through `sync(active:)`.**
/// `BackgroundKeepalive.shared` has a `private init` and no injectable platform
/// seam, and driving the real one would claim the process-wide
/// `AVAudioSession` (`.playback`, activated) that the Voice tests' doubles exist
/// to avoid. Its idempotence lives in `start()`/`stop()`'s `guard isRunning`
/// pair; `isRunning` is asserted here to be false in a fresh test process, which
/// is what those guards key off.
final class BackgroundKeepaliveTests: XCTestCase {

    // MARK: The pure arming decision (Dart group 1, 6 cases)

    func testArmedWhenBridgeModeIsOnAndTheDeviceIsPaired() {
        XCTAssertTrue(BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: true))
    }

    func testDisarmedWhenBridgeModeIsOff() {
        XCTAssertFalse(BackgroundKeepalive.shouldRun(bridgeEnabled: false, isPaired: true))
    }

    func testDisarmedWhenNotPaired() {
        XCTAssertFalse(BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: false),
                       "there is nowhere to stay connected to")
    }

    func testDisarmedWhenEverythingIsOff() {
        XCTAssertFalse(BackgroundKeepalive.shouldRun(bridgeEnabled: false, isPaired: false))
    }

    /// Flutter's `background: false` case. This port INVERTS it deliberately: a
    /// suspended app cannot start an audio session, so the session is held while
    /// the app is still in the foreground or the first background kills the
    /// socket. Pinned as a test so the deviation cannot be "fixed" by accident.
    func testForegroundStateIsNotPartOfTheDecision() {
        XCTAssertTrue(BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: true),
                      "armed in the foreground too — iOS cannot start a session once suspended")
    }

    /// Flutter's `voiceActive: true` case, likewise inverted: `.mixWithOthers`
    /// means the keepalive never takes the route from the voice session.
    func testAnActiveVoiceSessionDoesNotDisarmTheKeepalive() {
        XCTAssertTrue(BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: true),
                      "the silent session mixes; there is no session to fight over")
    }

    // MARK: Coalescing (Dart group 2)

    /// The transition guard's baseline: nothing has armed it in this process, so
    /// `stop()` is a no-op and `start()` is the first real transition.
    @MainActor
    func testTheSharedKeepaliveStartsIdle() {
        XCTAssertFalse(BackgroundKeepalive.shared.isRunning)
    }

    /// `sync(active:)` is a pure function of the flag — the same inputs always
    /// produce the same decision, which is what makes calling it on every state
    /// change (rather than tracking transitions) safe.
    func testTheDecisionIsStableForRepeatedInputs() {
        let first = BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: true)
        let second = BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: true)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first,
                          BackgroundKeepalive.shouldRun(bridgeEnabled: true, isPaired: false))
    }
}
