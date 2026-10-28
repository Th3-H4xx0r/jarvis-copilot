import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The app's voice orb next to the Dynamic Island's, drawn for a look before install
/// (written to RING_SNAPSHOT_DIR or /tmp/ringshots).
@MainActor
final class LiveOrbRenderTests: XCTestCase {
    func testTheAppOrbFrames() throws {
        let frames = OrbFrames.frames(count: 6, size: 120, start: 0, step: 0.6)
        let strip = HStack(spacing: 8) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Image(uiImage: frame).resizable().frame(width: 120, height: 120)
            }
            if let still = jarvisOrbUIImage {
                Image(uiImage: still).resizable().frame(width: 120, height: 120).clipShape(Circle())
            }
        }
        .padding(16)
        try RenderHarness.write(strip, size: CGSize(width: 7 * 128 + 32, height: 152), name: "orb-app-frames", settle: 0.5)
    }

    private typealias State = JarvisActivityAttributes.ContentState

    /// The island orb at its sizes, still, beside the app's.
    func testTheIslandOrb() throws {
        let row = HStack(spacing: 24) {
            JarvisLiveOrb(size: 120)
            JarvisLiveOrb(size: 44)
            JarvisLiveOrb(size: 24)
            JarvisLiveOrb(size: 24, glow: jcStateColor("speaking"))
            if let frame = OrbFrames.frames(count: 1, size: 120).first { Image(uiImage: frame) }
        }
        .padding(20)
        try RenderHarness.write(row, size: CGSize(width: 520, height: 170), name: "orb-island", settle: 0.5)
    }

    /// Frames of the orb moving, as the island plays it.
    func testTheIslandOrbMoves() throws {
        try RenderHarness.filmstrip(JarvisLiveOrb(size: 90).padding(10), size: CGSize(width: 110, height: 110),
                                    name: "orb-island-motion", changes: [{}],
                                    times: [0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75])
    }

    /// The Lock Screen card and island slots in each state.
    func testTheVoiceActivity() throws {
        let states: [State] = [
            State(state: "listening", transcript: "What's on my calendar tomorrow morning?"),
            State(state: "speaking", transcript: "What's on my calendar tomorrow morning?",
                  activity: "Stand-up with Maya at 9:30, then the dentist at 11."),
            State(state: "thinking", transcript: "Turn on the porch lights", activity: "Turning on Porch Lights…"),
            State(state: "idle"),
            State(state: "listening", connected: false),
        ]
        let page = VStack(spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                JarvisVoiceLockScreen(st: st)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            // The collapsed island: orb leading, the running timer trailing, either side of the camera.
            ForEach(["listening", "thinking", "speaking"], id: \.self) { state in
                HStack {
                    JarvisOrbArt(size: 24)
                    Spacer()
                    JarvisCompactTrailing(st: State(state: state))
                }
                .padding(.horizontal, 12)
                .frame(width: 250, height: 37)
                .background(Capsule().fill(.black))
            }
        }
        .padding(16)
        .background(Color(white: 0.35))
        try RenderHarness.write(page, size: CGSize(width: 402, height: 1000), name: "voice-activity", settle: 1)
    }
}
