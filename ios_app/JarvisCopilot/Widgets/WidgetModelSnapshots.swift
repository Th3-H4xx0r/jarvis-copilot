import Metal
import SceneKit
import UIKit
import WidgetKit

/// The wearables' 3D models as pictures for widgets: a widget can't run SceneKit, so the app
/// renders each model once (and again when the models change) into the App Group, where the
/// `model` block reads it.
@MainActor
enum WidgetModelSnapshots {
    /// The wearables that have a 3D model, by the key a design names them with.
    static let devices = ["ring", "x5ring", "glasses"]

    /// Bumped when a model's look changes, so phones render it again.
    static let version = 1
    private static let versionKey = "jc.widgets.modelsVersion"

    /// Renders whatever is missing or out of date, off the launch path.
    static func refreshIfNeeded(defaults: UserDefaults = .standard) {
        guard let dir = WidgetImages.modelURL("ring")?.deletingLastPathComponent() else { return }
        let missing = devices.contains { !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).png").path) }
        guard missing || defaults.integer(forKey: versionKey) != version else { return }
        Task { @MainActor in
            renderAll(into: dir)
            defaults.set(version, forKey: versionKey)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataHub.widgetKind)
        }
    }

    static func renderAll(into dir: URL, size: CGFloat = 400) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for device in devices {
            guard let png = render(device, size: size)?.pngData() else { continue }
            try? png.write(to: dir.appendingPathComponent("\(device).png"), options: .atomic)
        }
    }

    /// One model, front three-quarter view, on a transparent background.
    static func render(_ device: String, size: CGFloat = 400) -> UIImage? {
        let scene: SCNScene
        let camera: SCNNode
        switch device {
        case "ring":
            let live = RingModel.Live(spin: false)
            (scene, camera) = (live.scene, live.camera)
        case "x5ring":
            let live = X5Model.Live(spin: false)
            (scene, camera) = (live.scene, live.camera)
        case "glasses":
            let live = InmoGo3Model.Live(spin: false)
            (scene, camera) = (live.scene, live.camera)
        default:
            return nil
        }
        guard let metal = MTLCreateSystemDefaultDevice() else { return nil }
        scene.background.contents = UIColor.clear
        let renderer = SCNRenderer(device: metal, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let frame = CGSize(width: size, height: size)
        // The first frame starts any fade-in; the second lands after it.
        _ = renderer.snapshot(atTime: 0, with: frame, antialiasingMode: .multisampling4X)
        return renderer.snapshot(atTime: 2, with: frame, antialiasingMode: .multisampling4X)
    }
}
