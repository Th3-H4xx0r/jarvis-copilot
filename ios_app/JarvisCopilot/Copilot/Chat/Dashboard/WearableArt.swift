import SceneKit
import UIKit

/// Still pictures of the wearables, for places too small or too numerous for
/// the live 3D views: the Chat dashboard stacks several in a card.
///
/// The bottle, the scale and the glasses are rendered once from their real SceneKit
/// models — the same geometry, lights and materials as the Devices tab — and cached.
/// The rest have no model here, so they get their symbol.
@MainActor
enum WearableArt {
    private static var cache: [String: UIImage] = [:]

    /// A rendered picture, or nil for a kind that is drawn as a symbol.
    static func image(for kind: String) -> UIImage? {
        if let cached = cache[kind] { return cached }
        let rendered: UIImage?
        switch kind {
        case WearableKeepAlive.bottle:
            let live = BottleModel.Live(spin: false, tilt: -0.16)
            rendered = snapshot(live.scene, from: live.camera)
        case WearableKeepAlive.scale:
            let live = ScaleModel.Live(presentation: .card)
            rendered = snapshot(live.scene, from: live.camera)
        case WearableKeepAlive.glasses:
            let live = InmoGo3Model.Live(spin: false)
            rendered = snapshot(live.scene, from: live.camera)
        default:
            rendered = nil
        }
        cache[kind] = rendered
        return rendered
    }

    static func symbol(for kind: String) -> String {
        WearableKind(rawValue: kind)?.symbol ?? "dot.radiowaves.left.and.right"
    }

    private static let renderSide: CGFloat = 132

    private static func snapshot(_ scene: SCNScene, from camera: SCNNode) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0,
                                      with: CGSize(width: renderSide, height: renderSide),
                                      antialiasingMode: .multisampling4X)
        return image.size.width > 0 ? image : nil
    }
}
