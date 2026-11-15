import ActivityKit
import SwiftUI

/// Holo Drop's loader in the Dynamic Island, between Back Tap and the Orbit. The Back Tap
/// shortcut's first step starts it in the background, before Jarvis opens; the Orbit opening
/// ends it. Only system timers animate in a Live Activity, so the ring is a timer filling up.
struct HoloGrabActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var started: Date
        var until: Date
    }
}

enum HoloGrabText {
    static let title = "Holo Drop"
    static let detail = "Grabbing what's on screen…"
    /// How long the ring takes to fill: about the slowest Back Tap → Orbit seen.
    static let seconds: TimeInterval = 5

    static func state(now: Date = Date()) -> HoloGrabActivityAttributes.ContentState {
        .init(started: now, until: now.addingTimeInterval(seconds))
    }
}

/// The filling ring (white on black, like the other cards).
struct HoloGrabRing: View {
    let state: HoloGrabActivityAttributes.ContentState
    var size: CGFloat = 16

    var body: some View {
        ProgressView(timerInterval: state.started...state.until, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(.white)
        .frame(width: size, height: size)
    }
}

struct HoloGrabLockScreenView: View {
    let state: HoloGrabActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.point.up.braille.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(HoloGrabText.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(HoloGrabText.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            HoloGrabRing(state: state, size: 24)
        }
        .padding(16)
    }
}
