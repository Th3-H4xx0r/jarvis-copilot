import SceneKit
import SwiftUI

/// The door hub in 3D, built from primitives (no asset): the PHYSEN plug-in chime — a white rounded
/// body, its speaker grille and a status ring — with one of its door contacts (sensor + magnet)
/// beside it. The ring shows the alarm: dim when disarmed, the accent when armed, pulsing red when
/// a door opens while armed. Still (no spin), lit by the app's soft studio light.
struct DoorHubView: View {
    enum Look: Equatable {
        case idle, armed, alert
    }

    var state: Look
    var compact: Bool = true

    var body: some View {
        DoorHubScene(look: state, compact: compact)
    }
}

extension DoorHubView.Look {
    init(_ alarm: DoorAlarmInfo?) {
        guard let alarm else { self = .idle; return }
        self = alarm.isAlerting ? .alert : (alarm.isArmed ? .armed : .idle)
    }
}

private struct DoorHubScene: UIViewRepresentable {
    let look: DoorHubView.Look
    let compact: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        view.scene = Self.makeScene(compact: compact)
        Self.apply(look, to: view.scene)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        Self.apply(look, to: view.scene)
    }

    private static func material(_ color: UIColor, rough: CGFloat = 0.5, metal: CGFloat = 0, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = rough
        m.metalness.contents = metal
        if let glow { m.emission.contents = glow }
        return m
    }

    static func makeScene(compact: Bool) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()
        root.name = "hub-root"
        scene.rootNode.addChildNode(root)

        // The receiver: a white rounded block facing the camera.
        let body = SCNBox(width: 0.86, height: 0.86, length: 0.3, chamferRadius: 0.18)
        body.materials = [material(UIColor(white: 0.93, alpha: 1), rough: 0.35)]
        let bodyNode = SCNNode(geometry: body)
        root.addChildNode(bodyNode)

        // Speaker grille: a dark disc with holes in rings.
        let grille = SCNCylinder(radius: 0.24, height: 0.01)
        grille.materials = [material(UIColor(white: 0.18, alpha: 1), rough: 0.7)]
        let grilleNode = SCNNode(geometry: grille)
        grilleNode.eulerAngles.x = .pi / 2
        grilleNode.position = SCNVector3(0, 0.06, 0.151)
        root.addChildNode(grilleNode)
        for ring in 1...2 {
            let count = ring * 8
            for i in 0..<count {
                let a = Float(i) / Float(count) * 2 * .pi
                let r = Float(ring) * 0.075
                let hole = SCNNode(geometry: SCNSphere(radius: 0.012))
                hole.geometry?.materials = [material(.black, rough: 1)]
                hole.position = SCNVector3(r * cos(a), 0.06 + r * sin(a), 0.156)
                root.addChildNode(hole)
            }
        }

        // Status ring under the grille.
        let led = SCNTorus(ringRadius: 0.11, pipeRadius: 0.012)
        led.materials = [material(.white, rough: 0.2)]
        let ledNode = SCNNode(geometry: led)
        ledNode.name = "led"
        ledNode.eulerAngles.x = .pi / 2
        ledNode.position = SCNVector3(0, -0.26, 0.152)
        ledNode.scale = SCNVector3(1, 1, 0.35)
        root.addChildNode(ledNode)

        // A door contact: the sensor and its magnet, a small gap between them.
        let sensor = SCNBox(width: 0.16, height: 0.62, length: 0.12, chamferRadius: 0.04)
        sensor.materials = [material(UIColor(white: 0.9, alpha: 1), rough: 0.4)]
        let sensorNode = SCNNode(geometry: sensor)
        sensorNode.position = SCNVector3(0.72, -0.08, -0.02)
        root.addChildNode(sensorNode)
        let magnet = SCNBox(width: 0.1, height: 0.42, length: 0.1, chamferRadius: 0.03)
        magnet.materials = [material(UIColor(white: 0.88, alpha: 1), rough: 0.4)]
        let magnetNode = SCNNode(geometry: magnet)
        magnetNode.position = SCNVector3(0.92, -0.08, -0.02)
        root.addChildNode(magnetNode)
        let dot = SCNNode(geometry: SCNSphere(radius: 0.018))
        dot.name = "sensor-dot"
        dot.geometry?.materials = [material(.white, rough: 0.2)]
        dot.position = SCNVector3(0.72, 0.17, 0.045)
        root.addChildNode(dot)

        root.eulerAngles = SCNVector3(-0.08, -0.38, 0)
        root.position = SCNVector3(compact ? -0.12 : -0.18, 0, 0)

        // Soft studio light: a key, a fill, and ambient — no harsh speculars.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 420
        scene.rootNode.addChildNode(fill)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = compact ? 34 : 30
        camera.position = SCNVector3(0, 0, 3.0)
        scene.rootNode.addChildNode(camera)
        return scene
    }

    static func apply(_ look: DoorHubView.Look, to scene: SCNScene?) {
        guard let scene, let led = scene.rootNode.childNode(withName: "led", recursively: true),
              let dot = scene.rootNode.childNode(withName: "sensor-dot", recursively: true) else { return }
        let color: UIColor
        switch look {
        case .idle: color = UIColor(white: 0.55, alpha: 1)
        case .armed: color = UIColor(JcTheme.accent)
        case .alert: color = UIColor(JcTheme.danger)
        }
        for node in [led, dot] {
            node.geometry?.firstMaterial?.emission.contents = color
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.removeAction(forKey: "pulse")
            node.opacity = 1
        }
        if look == .alert {
            let pulse = SCNAction.repeatForever(.sequence([.fadeOpacity(to: 0.25, duration: 0.35),
                                                           .fadeOpacity(to: 1, duration: 0.35)]))
            led.runAction(pulse, forKey: "pulse")
        }
    }
}
