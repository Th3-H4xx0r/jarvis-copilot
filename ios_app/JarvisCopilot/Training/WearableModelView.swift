import SwiftUI

/// A wearable's own 3D model, small — the ring turning slowly, the bottle
/// and the scale as the Devices tab draws them. A kind with no model gets its
/// symbol in the same square, so rows line up either way.
struct WearableModelView: View {
    let kind: String
    var size: CGFloat = 56
    /// Turn the ring and the bottle (costs a continuous render while shown).
    var spins = true

    var body: some View {
        Group {
            switch kind {
            case WearableKeepAlive.ring:
                RingSceneView(spin: spins, tilt: 1.0, cameraDistance: 5.2, spinSeconds: 26, animatesAnywhere: true)
            case WearableKeepAlive.bottle:
                BottleSceneView(spin: spins, tilt: -0.16, animatesAnywhere: true)
            case WearableKeepAlive.scale:
                ScaleSceneView(state: .idle, weightText: nil, entrance: false, presentation: .thumbnail)
            default:
                Image(systemName: WearableArt.symbol(for: kind))
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
