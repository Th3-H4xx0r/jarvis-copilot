import UIKit
import XCTest
@testable import JarvisCopilot

/// The car's voice screen: which states it shows, what they say, and that the
/// orb really is drawn into its frames.
@MainActor
final class CarPlayVoiceTests: XCTestCase {




    func testOrbFramesAreDrawn() throws {
        let frames = OrbFrames.frames(count: 2, size: 60)
        XCTAssertEqual(frames.count, 2)
        let centre = try XCTUnwrap(alphaAtCentre(frames[0]))
        XCTAssertGreaterThan(centre, 0.5, "the sphere fills the middle of the frame")
    }

    func testEveryShownStateHasAnOrb() {
        for state in [VoiceState.connecting, .listening, .thinking, .speaking, .idle, .error] {
            XCTAssertNotNil(OrbFrames.animated(for: state), "\(state)")
        }
    }

    /// The JARVIS Voice widget opens the car's voice screen; other links go to the phone's router.
    func testOnlyTheVoiceLinkOpensCarPlayVoice() {
        XCTAssertTrue(CarPlayLinks.isVoice(URL(string: "jarviscopilot://voice")!))
        XCTAssertFalse(CarPlayLinks.isVoice(URL(string: "jarviscopilot://chat?session=a")!))
        XCTAssertFalse(CarPlayLinks.isVoice(URL(string: "https://voice.example.com")!))
    }

    private func alphaAtCentre(_ image: UIImage) -> CGFloat? {
        guard let cg = image.cgImage else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return CGFloat(pixel[3]) / 255
    }

    /// The car can't answer a permission prompt: only a granted mic counts.
    func testOnlyAGrantedMicCounts() {
        XCTAssertTrue(CarPlayVoiceState.micAllowed(.granted))
        XCTAssertFalse(CarPlayVoiceState.micAllowed(.undetermined))
        XCTAssertFalse(CarPlayVoiceState.micAllowed(.denied))
    }


    /// One still frame of the real orb, for the Voice tab's header and row.
    func testStillOrbIsDrawnAtTheAskedSize() throws {
        let still = try XCTUnwrap(OrbFrames.still(size: 100))
        XCTAssertEqual(still.size, CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(try XCTUnwrap(alphaAtCentre(still)), 0.5)
    }

    // MARK: The Voice tab is the voice screen (no pop-up)

    func testIdleOffersTalk() {
        XCTAssertEqual(CarPlayScreens.voiceButtons(active: false, muted: false, pushToTalk: false), [.talk])
    }

    func testAConversationOffersMuteAndStop() {
        XCTAssertEqual(CarPlayScreens.voiceButtons(active: true, muted: false, pushToTalk: false), [.mute, .stop])
        XCTAssertEqual(CarPlayScreens.voiceButtons(active: true, muted: true, pushToTalk: false), [.unmute, .stop])
        XCTAssertEqual(CarPlayScreens.voiceButtons(active: true, muted: false, pushToTalk: true), [.send, .stop])
    }

    func testTheStateLineSaysWhereToFixTheMic() {
        XCTAssertEqual(CarPlayScreens.voiceStateText(state: .idle, error: nil, micAllowed: false),
                       "Allow the microphone on your iPhone")
        XCTAssertEqual(CarPlayScreens.voiceStateText(state: .listening, error: nil, micAllowed: true), "Listening…")
        XCTAssertEqual(CarPlayScreens.voiceStateText(state: .idle, error: nil, micAllowed: true), "Tap Talk to start")
        XCTAssertEqual(CarPlayScreens.voiceStateText(state: .idle, error: "Server down", micAllowed: true), "Server down")
    }

    // MARK: The full-screen voice screen (like Claude's)

    func testFiveScreenStatesAndIdleClosesTheScreen() {
        XCTAssertEqual(CarPlayVoiceState.shown, [.connecting, .listening, .thinking, .speaking, .error],
                       "CarPlay allows at most five voice states, the first one shown on open")
        XCTAssertEqual(CarPlayVoiceState.id(for: .listening), "listening")
        XCTAssertNil(CarPlayVoiceState.id(for: .idle), "a finished conversation closes the screen")
    }

    func testTitlesSayWhatIsHappening() {
        XCTAssertEqual(CarPlayVoiceState.titles(for: .listening, micAllowed: true).first, "Listening…")
        XCTAssertEqual(CarPlayVoiceState.titles(for: .speaking, micAllowed: true).first, "Speaking")
        for state in CarPlayVoiceState.shown {
            let titles = CarPlayVoiceState.titles(for: state, micAllowed: true)
            XCTAssertFalse(titles.isEmpty)
            XCTAssertEqual(titles, titles.sorted { $0.count > $1.count }, "variants run longest first")
        }
    }

    func testErrorAsksForTheMicOnlyWhenTheMicIsOff() {
        XCTAssertEqual(CarPlayVoiceState.titles(for: .error, micAllowed: false).first, "Allow the microphone on your iPhone")
        XCTAssertNotEqual(CarPlayVoiceState.titles(for: .error, micAllowed: true).first, "Allow the microphone on your iPhone")
    }

    /// CarPlay rate-limits state changes: re-sending the same state could drop the next real one.
    func testActivateOnlyWhenTheStateChanges() {
        XCTAssertFalse(CarPlayVoiceState.needsActivation(active: "listening", next: "listening"))
        XCTAssertTrue(CarPlayVoiceState.needsActivation(active: "listening", next: "thinking"))
        XCTAssertTrue(CarPlayVoiceState.needsActivation(active: nil, next: "connecting"))
    }

    /// CarPlay: recording only while the voice screen shows — so an active session always gets it.
    func testAnActiveSessionAlwaysGetsTheScreen() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .listening, hasError: false, showing: false, stopping: false), .show)
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .connecting, hasError: false, showing: false, stopping: false), .show)
    }

    /// After Stop, the session winding down must not bring the screen back.
    func testStoppingDoesNotReopenTheScreen() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .speaking, hasError: false, showing: false, stopping: true), .none)
    }

    func testTheScreenTracksTheState() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .thinking, hasError: false, showing: true, stopping: false), .activate("thinking"))
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .idle, hasError: true, showing: true, stopping: false), .activate("error"))
    }

    /// A blip through idle (a restart between turns) is not the end: hide only if idle lasts.
    func testIdleHidesOnlyAfterAPause() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .idle, hasError: false, showing: true, stopping: false), .hideSoon)
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .idle, hasError: false, showing: false, stopping: false), .none)
    }

    // MARK: Animation, then text

    /// When Jarvis starts speaking, the full-screen orb steps aside for the Voice tab's text.
    func testSpeakingSwitchesToTheText() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .speaking, hasError: false, showing: true, stopping: false), .hideForText)
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .speaking, hasError: false, showing: false, stopping: false), .none)
    }

    /// Listening again after the reply: the animation comes back.
    func testListeningAgainBringsTheAnimationBack() {
        XCTAssertEqual(CarPlayVoiceMirror.step(state: .listening, hasError: false, showing: false, stopping: false), .show)
    }
}
