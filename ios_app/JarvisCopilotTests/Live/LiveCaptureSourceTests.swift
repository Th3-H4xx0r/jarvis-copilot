import XCTest
@testable import JarvisCopilot

/// Capture-source selection, and the `mic` capability seam.
///
/// The requirement these pin: a wearable bought LATER must appear without a code
/// change. So the tests use capability names no source file mentions.
@MainActor
final class LiveCaptureSourceTests: XCTestCase {

    // MARK: - The mic capability

    /// A device Jarvis has never heard of is offered purely because it SAYS it has a
    /// mic. No device name, model or kind is consulted.
    func testADeviceIsOfferedBecauseItAdvertisesAMicNotBecauseWeKnowItsName() {
        XCTAssertTrue(LiveMicCapability.advertises(["glasses_mic_stream_start"]))
        XCTAssertTrue(LiveMicCapability.advertises(["start_microphone"]))
        XCTAssertTrue(LiveMicCapability.advertises(["audio_in_open"]))
        XCTAssertTrue(LiveMicCapability.advertises(["listen_begin"]))
        XCTAssertTrue(LiveMicCapability.advertises(["MIC_STREAM"]), "matching must be case-insensitive")
    }

    func testADeviceWithNoAudioCapabilityIsNotOffered() {
        XCTAssertFalse(LiveMicCapability.advertises([]))
        XCTAssertFalse(LiveMicCapability.advertises(["set_led", "read_battery", "vibrate"]))
    }

    /// Being able to MUTE a mic, or report one, is not being able to hand us audio.
    func testControlAndStatusCapabilitiesAreNotMistakenForACapture() {
        XCTAssertFalse(LiveMicCapability.advertises(["mic_mute"]))
        XCTAssertFalse(LiveMicCapability.advertises(["microphone_status"]))
        XCTAssertFalse(LiveMicCapability.advertises(["mic_level"]))
        XCTAssertFalse(LiveMicCapability.advertises(["audio_volume"]))
    }

    /// The firmware author chooses those names, so a device that spells it something
    /// unanticipated must not need an app release.
    func testAUserOverrideBeatsWhateverTheDeviceAdvertises() {
        let store = MemoryKeyValueStore()
        XCTAssertFalse(LiveMicCapability.hasMic(deviceID: "d1", advertised: ["set_led"], store: store))

        LiveMicCapability.setOverride(true, for: "d1", store: store)
        XCTAssertTrue(LiveMicCapability.hasMic(deviceID: "d1", advertised: ["set_led"], store: store))

        // And the reverse: a device that advertises a mic can be turned off.
        LiveMicCapability.setOverride(false, for: "d2", store: store)
        XCTAssertFalse(LiveMicCapability.hasMic(deviceID: "d2", advertised: ["mic_stream"], store: store))
    }

    func testClearingAnOverrideReturnsToWhatTheDeviceSays() {
        let store = MemoryKeyValueStore()
        LiveMicCapability.setOverride(false, for: "d", store: store)
        LiveMicCapability.setOverride(nil, for: "d", store: store)
        XCTAssertNil(LiveMicCapability.override("d", store: store))
        XCTAssertTrue(LiveMicCapability.hasMic(deviceID: "d", advertised: ["mic_stream"], store: store))
    }

    /// Overrides are per device, so answering for one wearable says nothing about
    /// another.
    func testOverridesAreScopedToOneDevice() {
        let store = MemoryKeyValueStore()
        LiveMicCapability.setOverride(true, for: "left", store: store)
        XCTAssertNil(LiveMicCapability.override("right", store: store))
    }

    // MARK: - Resolution

    private func source(_ id: String, kind: LiveCaptureSource.Kind = .route,
                        available: Bool = true, canStream: Bool = true) -> LiveCaptureSource {
        LiveCaptureSource(id: id, kind: kind, label: id, detail: nil, symbol: "mic",
                          available: available, canStream: canStream)
    }

    func testAStoredChoiceResolvesToItselfWhenItIsStillThere() {
        let list = [LiveCaptureSource.automatic, source("route:airpods")]
        XCTAssertEqual(LiveCaptureSources.resolve(id: "route:airpods", among: list).id, "route:airpods")
    }

    /// Unplugging headphones must NOT stop an ambient capture. It falls back and
    /// relabels itself.
    func testASourceThatHasGoneAwayFallsBackToAutomatic() {
        let list = [LiveCaptureSource.automatic, source("route:builtin")]
        XCTAssertEqual(LiveCaptureSources.resolve(id: "route:gone", among: list).kind, .automatic)
    }

    func testAnUnavailableSourceIsNotResolvedTo() {
        let list = [LiveCaptureSource.automatic,
                    source("wearable:glasses", kind: .wearable, available: false, canStream: false)]
        XCTAssertEqual(LiveCaptureSources.resolve(id: "wearable:glasses", among: list).kind, .automatic,
                       "a disconnected wearable must not be selected as the live input")
    }

    func testResolvingWithNoStoredChoiceGivesAutomatic() {
        let list = [LiveCaptureSource.automatic, source("route:builtin")]
        XCTAssertEqual(LiveCaptureSources.resolve(id: nil, among: list).kind, .automatic)
        XCTAssertEqual(LiveCaptureSources.resolve(id: "", among: list).kind, .automatic)
    }

    /// Even with an empty list the caller always gets something usable, rather than
    /// a nil that a recording path would have to special-case.
    func testResolvingAgainstAnEmptyListStillGivesAutomatic() {
        XCTAssertEqual(LiveCaptureSources.resolve(id: "route:x", among: []).kind, .automatic)
    }

    /// A stored choice that cannot carry audio must never come back as the active
    /// microphone. It would be NAMED on the settings screen while the phone quietly
    /// recorded, and with no notice — because `select` was not what chose it that time.
    func testAConnectedButNonStreamingSourceIsNeverResolvedTo() {
        let list = [LiveCaptureSource.automatic,
                    source("wearable:glasses", kind: .wearable, available: true, canStream: false)]
        XCTAssertEqual(LiveCaptureSources.resolve(id: "wearable:glasses", among: list).kind,
                       .automatic)
    }

    // MARK: - Honesty

    /// No wearable transport carries a mic stream into this app today. The flag says
    /// so, and `apply` refuses, so nothing can present a recording state over a
    /// source that captures nothing.
    func testAWearableSourceReportsThatItCannotStreamAndApplyingItIsRefused() {
        let wearable = source("wearable:pod", kind: .wearable, canStream: false)
        XCTAssertFalse(wearable.canStream)
        XCTAssertFalse(LiveCaptureSources.apply(wearable))
    }

    func testAutomaticIsAlwaysAvailableAndStreamable() {
        XCTAssertTrue(LiveCaptureSource.automatic.available)
        XCTAssertTrue(LiveCaptureSource.automatic.canStream)
        XCTAssertEqual(LiveCaptureSource.automatic.kind, .automatic)
    }
}
