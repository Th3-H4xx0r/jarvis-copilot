import XCTest
@testable import JarvisCopilot

/// How the phone decides the INMO GO3 is on its audio route. The glasses pair as an
/// ordinary Bluetooth headset, so everything here is read off `AVAudioSession` ports.
final class GlassesAudioLinkTests: XCTestCase {

    private func port(_ name: String, _ uid: String, bluetooth: Bool = true) -> GlassesAudioPort {
        GlassesAudioPort(name: name, uid: uid, isBluetooth: bluetooth)
    }

    private let speaker = GlassesAudioPort(name: "Speaker", uid: "Built-In Speaker", isBluetooth: false)
    private let phoneMic = GlassesAudioPort(name: "iPhone Microphone", uid: "Built-In Microphone", isBluetooth: false)

    // MARK: Names

    func testGo3NamesAreRecognised() {
        for name in ["INMO GO3", "INMO GO3-1A2B", "inmo go 3", "INMO", "INMO_GO3", "INMOGO3", "My INMO"] {
            XCTAssertTrue(GlassesAudioPort.looksLikeGo3(name), name)
        }
    }

    /// "GO 3" alone is a JBL speaker's real name, and "inmo" hides inside other words.
    func testOtherHeadsetsAreNot() {
        for name in ["AirPods Pro", "GoPro HERO", "JBL GO 3", "Go3 Glasses", "Spinmotion", "Speaker", ""] {
            XCTAssertFalse(GlassesAudioPort.looksLikeGo3(name), name)
        }
    }

    // MARK: Device key

    /// A2DP and HFP are two ports with two uids for one pair of glasses; both carry the MAC.
    func testBothProfilesShareOneDeviceKey() {
        XCTAssertEqual(port("x", "AA:BB:CC:DD:EE:FF-tacl").deviceKey, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(port("x", "aa:bb:cc:dd:ee:ff-tsco").deviceKey, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(port("x", "some-opaque-uid").deviceKey, "some-opaque-uid")
    }

    // MARK: Resolving the route

    func testGlassesPlayingAndListening() {
        let a2dp = port("INMO GO3", "AA:BB:CC:DD:EE:FF-tacl")
        let hfp = port("INMO GO3", "AA:BB:CC:DD:EE:FF-tsco")
        let state = GlassesRouteState.resolve(outputs: [hfp], inputs: [hfp], available: [phoneMic, hfp],
                                              rememberedKey: nil)
        XCTAssertTrue(state.connected)
        XCTAssertTrue(state.speakers)
        XCTAssertTrue(state.microphone)
        XCTAssertEqual(state.glasses?.deviceKey, a2dp.deviceKey)
        XCTAssertNil(state.otherHeadset)
    }

    /// Paired and in range, but the reply is going to the phone speaker: still connected.
    func testConnectedWhileAudioIsOnThePhone() {
        let hfp = port("INMO GO3", "AA:BB:CC:DD:EE:FF-tsco")
        let state = GlassesRouteState.resolve(outputs: [speaker], inputs: [phoneMic], available: [phoneMic, hfp],
                                              rememberedKey: nil)
        XCTAssertTrue(state.connected)
        XCTAssertFalse(state.speakers)
        XCTAssertFalse(state.microphone)
    }

    /// Whatever the GO3 calls itself, a device the user said is their glasses is matched by its MAC.
    func testARememberedDeviceMatchesUnderAnyName() {
        let odd = port("IMG301_8F2A", "AA:BB:CC:DD:EE:FF-tacl")
        let state = GlassesRouteState.resolve(outputs: [odd], inputs: [], available: [],
                                              rememberedKey: "AA:BB:CC:DD:EE:FF")
        XCTAssertTrue(state.connected)
        XCTAssertEqual(state.glasses?.name, "IMG301_8F2A")
    }

    /// Once a pair is known, another INMO-named device is not them — a claim is never
    /// overwritten by whatever happens to be playing.
    func testOnceKnownOnlyThatDeviceMatches() {
        let other = port("INMO GO3", "11:22:33:44:55:66-tacl")
        let state = GlassesRouteState.resolve(outputs: [other], inputs: [], available: [],
                                              rememberedKey: "AA:BB:CC:DD:EE:FF")
        XCTAssertFalse(state.connected)
    }

    /// A port with no uid has no identity to remember, so it never counts.
    func testAPortWithNoUidNeverMatches() {
        let blank = port("INMO GO3", "")
        let state = GlassesRouteState.resolve(outputs: [blank], inputs: [], available: [], rememberedKey: nil)
        XCTAssertFalse(state.connected)
    }

    /// An unknown Bluetooth headset is offered as "Use … as my glasses", not assumed.
    func testAnUnknownHeadsetIsOfferedNotAssumed() {
        let buds = port("Galaxy Buds", "11:22:33:44:55:66-tacl")
        let state = GlassesRouteState.resolve(outputs: [buds], inputs: [], available: [], rememberedKey: nil)
        XCTAssertFalse(state.connected)
        XCTAssertEqual(state.otherHeadset?.name, "Galaxy Buds")
    }

    /// Once the glasses are recognised there is nothing to offer.
    func testNoOfferWhileTheGlassesAreMatched() {
        let glasses = port("INMO GO3", "AA:BB:CC:DD:EE:FF-tacl")
        let buds = port("Galaxy Buds", "11:22:33:44:55:66-tsco")
        let state = GlassesRouteState.resolve(outputs: [glasses], inputs: [buds], available: [buds],
                                              rememberedKey: nil)
        XCTAssertTrue(state.connected)
        XCTAssertNil(state.otherHeadset)
    }

    /// A wired or USB device with a GO3-like name is not the glasses.
    func testOnlyBluetoothPortsCount() {
        let usb = port("INMO GO3", "usb-1", bluetooth: false)
        let state = GlassesRouteState.resolve(outputs: [usb], inputs: [], available: [], rememberedKey: nil)
        XCTAssertFalse(state.connected)
        XCTAssertNil(state.otherHeadset)
    }

    func testNothingConnected() {
        let state = GlassesRouteState.resolve(outputs: [speaker], inputs: [phoneMic], available: [phoneMic],
                                              rememberedKey: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(state, .none)
    }
}
