import SwiftUI
import UIKit

/// The phone's voice orb (`OrbShader.metal`'s `setupOrb`) rendered into still
/// frames, for the car's voice screen — CarPlay takes an animated `UIImage`,
/// never a live view. Each state loops a few seconds of the shader forwards and
/// back, so the loop has no seam; speaking adds the phone's gentle pulse.
@MainActor
enum OrbFrames {
    /// CarPlay's voice-state image is at most 150 × 150 pt.
    static let side: CGFloat = 120
    private static var cache: [VoiceState: UIImage] = [:]

    /// `count` frames of the orb starting at shader time `start`, `step` seconds apart.
    static func frames(count: Int, size: CGFloat = side, start: Double = 0, step: Double = 0.1,
                       pulse: (Int) -> CGFloat = { _ in 1 }) -> [UIImage] {
        (0..<count).compactMap { i in
            let renderer = ImageRenderer(content: OrbFrameView(size: size, t: start + Double(i) * step, scale: pulse(i)))
            renderer.scale = 2
            renderer.isOpaque = false
            return renderer.uiImage
        }
    }

    /// The looping orb for one voice state (cached — rendering costs ~a frame each).
    static func animated(for state: VoiceState) -> UIImage? {
        if let cached = cache[state] { return cached }
        let image: UIImage?
        switch state {
        case .listening: image = loop(frames(count: 12, step: 0.12), duration: 2.4)
        case .thinking: image = loop(frames(count: 12, step: 0.3), duration: 1.2)
        case .speaking:
            image = loop(frames(count: 12, step: 0.12, pulse: { 1 + 0.06 * CGFloat(sin(Double($0) / 11 * .pi)) }), duration: 1.2)
        case .connecting, .error, .idle:
            image = frames(count: 1).first
        }
        let result = image ?? jarvisOrbUIImage
        cache[state] = result
        return result
    }

    /// Render every state's loop ahead of the first Talk tap, a state at a time.
    static func prewarm() async {
        for state in CarPlayVoiceState.shown {
            _ = animated(for: state)
            await Task.yield()
        }
    }

    /// Drop the frames (~9 MB) when the car disconnects.
    static func clear() { cache.removeAll() }

    /// Forwards then back, so the last frame meets the first.
    private static func loop(_ frames: [UIImage], duration: TimeInterval) -> UIImage? {
        guard frames.count > 1 else { return frames.first }
        return UIImage.animatedImage(with: frames + frames.dropFirst().dropLast().reversed(), duration: duration)
    }
}

/// One frame: the shader surface is the sphere / 0.53 (as `VoiceOrb` sizes it),
/// cropped to the sphere.
private struct OrbFrameView: View {
    let size: CGFloat
    let t: Double
    var scale: CGFloat = 1

    var body: some View {
        let surface = size / 0.53
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.default.setupOrb(.float2(surface, surface), .float(t)))
            .frame(width: surface, height: surface)
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .clipped()
    }
}
