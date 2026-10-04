import UIKit
import XCTest
@testable import JarvisCopilot

/// The car's voice screen: which states it shows, what they say, and that the
/// orb really is drawn into its frames.
@MainActor
final class CarPlayVoiceTests: XCTestCase {

    func testFiveScreenStatesAndIdleClosesTheScreen() {
        XCTAssertEqual(CarPlayVoiceState.shown, [.connecting, .listening, .thinking, .speaking, .error],
                       "CarPlay allows at most five voice states, the first one shown on open")
        XCTAssertEqual(CarPlayVoiceState.id(for: .listening), "listening")
        XCTAssertNil(CarPlayVoiceState.id(for: .idle), "a finished conversation closes the screen")
    }

    func testTitlesSayWhatIsHappening() {
        XCTAssertEqual(CarPlayVoiceState.titles(for: .listening, micAllowed: true).first, "Listening…")
        XCTAssertEqual(CarPlayVoiceState.titles(for: .speaking, micAllowed: true).first, "Jarvis")
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

    func testOrbFramesAreDrawn() throws {
        let frames = OrbFrames.frames(count: 2, size: 60)
        XCTAssertEqual(frames.count, 2)
        let centre = try XCTUnwrap(alphaAtCentre(frames[0]))
        XCTAssertGreaterThan(centre, 0.5, "the sphere fills the middle of the frame")
    }

    func testEveryShownStateHasAnOrb() {
        for state in CarPlayVoiceState.shown {
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
}
