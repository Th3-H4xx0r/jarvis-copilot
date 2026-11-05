import AVFoundation
import SwiftUI
import UIKit

// "Both" on a clip's page: the front and rear videos play as one. Each had its own player with its own
// controls and drifted apart (2026-11-04, his call: "a shared seek bar which controls both"). Now neither
// has controls; one bar under them plays, pauses and seeks the two together, lined up by the time each
// clip started (front and rear files can start a second or two apart).

/// A video with no controls of its own.
struct DashcamVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// One clock for two players: the lead (front) sets the time; the follower (rear) is kept on it.
@MainActor
final class DashcamDualClock: ObservableObject {
    /// Seconds into the lead clip.
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var scrubbing = false

    private var lead: AVPlayer?
    private var follow: AVPlayer?
    /// Follower time = lead time + offset (the lead's start minus the follower's, in seconds).
    private var offset: Double = 0
    private var fallbackDuration: Double = 0
    private var observer: Any?
    private var wasPlaying = false
    /// The follower is this far off before it is put back on the lead (a seek costs a visible hitch).
    static let maxDrift: Double = 0.25

    /// Points the clock at two players (again after either reloads, e.g. HD); the follower jumps to the lead.
    func attach(lead: AVPlayer, follow: AVPlayer, offset: Double, fallbackDuration: Double) {
        guard lead !== self.lead || follow !== self.follow || offset != self.offset else { return }
        detach()
        self.lead = lead
        self.follow = follow
        self.offset = offset
        self.fallbackDuration = fallbackDuration
        follow.isMuted = true
        observer = lead.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        align(precise: true)
        tick()
    }

    func detach() {
        if let observer, let lead { lead.removeTimeObserver(observer) }
        observer = nil
        lead = nil
        follow = nil
    }

    func toggle() {
        guard let lead else { return }
        if lead.rate > 0 {
            lead.pause()
            follow?.pause()
        } else {
            if duration > 0, time >= duration - 0.25 { seek(to: 0) }   // ended: from the top
            lead.play()
            align(precise: false)
        }
        tick()
    }

    func seek(to seconds: Double) {
        guard let lead else { return }
        let t = max(0, min(seconds, duration > 0 ? duration : seconds))
        time = t
        lead.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        follow?.seek(to: CMTime(seconds: max(0, t + offset), preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The seek bar picked up: both hold still while it moves, and go on as before when it's let go.
    func scrub(_ active: Bool) {
        if active {
            wasPlaying = (lead?.rate ?? 0) > 0
            scrubbing = true
            lead?.pause()
            follow?.pause()
        } else {
            scrubbing = false
            if wasPlaying { lead?.play(); align(precise: false) }
            tick()
        }
    }

    private func tick() {
        guard let lead else { return }
        let now = lead.currentTime().seconds
        if !scrubbing { time = now.isFinite ? max(0, now) : 0 }
        if let d = lead.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d } else { duration = fallbackDuration }
        playing = lead.rate > 0
        if playing { align(precise: false) }
    }

    /// Puts the follower where the lead is, and at its rate. Before its clip starts it waits at the start.
    private func align(precise: Bool) {
        guard let lead, let follow else { return }
        let want = lead.currentTime().seconds + offset
        guard want.isFinite else { return }
        if want < 0 {
            follow.pause()
            if follow.currentTime().seconds > 0.05 { follow.seek(to: .zero) }
            return
        }
        let have = follow.currentTime().seconds
        if precise || !have.isFinite || abs(have - want) > Self.maxDrift {
            follow.seek(to: CMTime(seconds: want, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if lead.rate > 0, follow.rate != lead.rate { follow.rate = lead.rate }
        if lead.rate == 0, follow.rate != 0 { follow.pause() }
    }
}

/// The one bar under both videos: play/pause, where it is, the seek bar, how long.
struct DashcamDualControls: View {
    @ObservedObject var clock: DashcamDualClock

    var body: some View {
        HStack(spacing: 12) {
            Button { clock.toggle() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clock.playing ? "Pause both" : "Play both")
            Text(Self.clock(clock.time))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(JcTheme.text)
                .frame(minWidth: 36, alignment: .leading)
            Slider(value: Binding(get: { clock.time }, set: { clock.seek(to: $0) }),
                   in: 0...max(clock.duration, 0.1),
                   onEditingChanged: { clock.scrub($0) })
                .tint(.white)
                .accessibilityLabel("Position in both videos")
            Text(Self.clock(clock.duration))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(JcTheme.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(JcTheme.border, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    /// 0:07, 1:00.
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
