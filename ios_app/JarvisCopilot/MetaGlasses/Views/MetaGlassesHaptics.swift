import AVFoundation
import UIKit

/// What your finger feels on the simulated glasses' right arm, so the touchpad and capture button
/// read like the real ones: a soft tick per tap, a firm thump when a hold registers, ticks along a
/// swipe, a crisp shutter for a photo.
@MainActor
enum MetaGlassesHaptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let selection = UISelectionFeedbackGenerator()

    /// The touchpad gesture's feel. Taps repeat at the glasses' tap rhythm (~110 ms apart).
    static func play(_ gesture: MetaTouchGesture) {
        switch gesture {
        case .tap: taps(1)
        case .doubleTap: taps(2)
        case .tripleTap: taps(3)
        case .hold: holdRegistered()
        case .swipeForward, .swipeBackward: swipe()
        case .capture: shutter()
        }
    }

    /// Finger down on a hold: a faint tick; `holdRegistered` follows once it counts as a hold.
    static func pressStarted() {
        soft.prepare()
        soft.impactOccurred(intensity: 0.5)
        rigid.prepare()
    }

    static func holdRegistered() {
        rigid.impactOccurred(intensity: 1.0)
    }

    static func taps(_ count: Int) {
        light.prepare()
        for i in 0 ..< count {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(110 * i)) {
                light.impactOccurred(intensity: 0.85)
            }
        }
    }

    static func swipe() {
        selection.prepare()
        for i in 0 ..< 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35 * i)) { selection.selectionChanged() }
        }
    }

    /// The capture button: a press, then the shutter.
    static func shutter() {
        medium.prepare()
        medium.impactOccurred(intensity: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90)) { rigid.impactOccurred(intensity: 1.0) }
    }

    /// Recording starts (one heavy thump) or stops (two medium).
    static func recording(started: Bool) {
        if started {
            heavy.impactOccurred(intensity: 1.0)
        } else {
            medium.impactOccurred(intensity: 0.9)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) { medium.impactOccurred(intensity: 0.9) }
        }
    }

    /// iOS mutes app haptics while the app records unless the session allows them. The simulator
    /// holds the mic (wake-word listening, hold to talk, the assistant), so allow them while it does,
    /// then put it back so a normal voice chat isn't buzzed into its own mic (2026-11-22: "the
    /// haptics don't work anymore" once "Listen for Hey Jarvis" was on).
    static func allowWhileRecording(_ on: Bool) {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(on)
    }

    /// Hold to talk: the mic opens / closes.
    static func micOpened() { medium.impactOccurred(intensity: 0.7) }
    static func micClosed() { light.impactOccurred(intensity: 0.6) }
}
