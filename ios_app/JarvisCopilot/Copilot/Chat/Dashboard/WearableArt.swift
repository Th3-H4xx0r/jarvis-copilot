import SceneKit
import UIKit

/// Still pictures of the wearables, for places too small or too numerous for
/// the live 3D views: the Chat dashboard stacks several in a card.
///
/// The bottle, the scale and the glasses are rendered once from their real SceneKit
/// models — the same geometry, lights and materials as the Devices tab — and cached.
/// The ring and the ESP32 boards have no model, so they get a symbol.
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
        switch kind {
        case WearableKeepAlive.bottle: return "waterbottle"
        case WearableKeepAlive.scale:  return "scalemass"
        case WearableKeepAlive.ring:   return "circle.circle"
        case WearableKeepAlive.esp32:  return "cpu"
        case WearableKeepAlive.glasses: return "eyeglasses"
        default:                       return "dot.radiowaves.left.and.right"
        }
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
