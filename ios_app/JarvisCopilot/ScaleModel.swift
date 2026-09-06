import SceneKit

#if canImport(UIKit)
import UIKit
private typealias ScalePlatformColor = UIColor
#else
import AppKit
private typealias ScalePlatformColor = NSColor
#endif

enum ScaleVisualState: Equatable {
    case idle
    case measuring
    case stable
}

/// Procedural ESF551 model traced from the user's top and side reference photos.
/// Scene units preserve the photographed proportions: a square 300 mm glass deck,
/// thin top sheet, deeper polymer base, four capsule electrodes and four round feet.
enum ScaleModel {
    enum Presentation {
        case card
        case detail
    }

    static let deckWidth: CGFloat = 1.42
    static let glassHeight: CGFloat = 0.045

    struct Parts {
        let pivot: SCNNode
        let spinner: SCNNode
        let deck: SCNNode
        let electrodes: [SCNNode]
        let glow: SCNNode
        let displayText: SCNNode
    }

    private static func material(_ color: ScalePlatformColor,
                                 roughness: CGFloat,
                                 metalness: CGFloat = 0) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }

    private static func glassMaterial() -> SCNMaterial {
        let material = material(ScalePlatformColor(white: 0.025, alpha: 1), roughness: 0.30)
        material.clearCoat.contents = 0.52
        material.clearCoatRoughness.contents = 0.25
        material.reflective.contents = ScalePlatformColor(white: 0.10, alpha: 1)
        return material
    }

    private static func electrodeNode(index: Int, x: Float, z: Float, angle: Float) -> SCNNode {
        let holder = SCNNode()
        holder.name = "electrode\(index)"
        holder.position = SCNVector3(x, 0.108, z)
        holder.eulerAngles = SCNVector3(0, angle, 0)

        // A flattened capsule produces the rounded brushed-steel plates in the photo.
        let capsule = SCNCapsule(capRadius: 0.094, height: 0.42)
        let steel = material(ScalePlatformColor(white: 0.34, alpha: 1), roughness: 0.48, metalness: 0.72)
        capsule.materials = [steel]
        capsule.radialSegmentCount = 48
        capsule.capSegmentCount = 16
        let plate = SCNNode(geometry: capsule)
        plate.eulerAngles.x = .pi / 2
        plate.scale.z = 0.075
        holder.addChildNode(plate)

        // A subtle inner highlight makes the radial brushing read at phone size.
        let highlight = SCNBox(width: 0.008, height: 0.004, length: 0.25, chamferRadius: 0.004)
        highlight.materials = [material(ScalePlatformColor(white: 0.55, alpha: 0.32), roughness: 0.44, metalness: 0.65)]
        let highlightNode = SCNNode(geometry: highlight)
        highlightNode.position.y = 0.018
        holder.addChildNode(highlightNode)
        return holder
    }

    static func makeNode() -> Parts {
        let pivot = SCNNode()
        let spinner = SCNNode()
        pivot.addChildNode(spinner)

        let deck = SCNNode()
        deck.name = "scaleDeckAssembly"
        spinner.addChildNode(deck)

        let baseGeometry = SCNBox(width: 1.36, height: 0.105, length: 1.36, chamferRadius: 0.105)
        baseGeometry.chamferSegmentCount = 18
        baseGeometry.materials = [material(ScalePlatformColor(white: 0.035, alpha: 1), roughness: 0.68)]
        let base = SCNNode(geometry: baseGeometry)
        base.name = "polymerBase"
        base.position.y = 0.014
        deck.addChildNode(base)

        let glassGeometry = SCNBox(width: deckWidth, height: glassHeight,
                                   length: deckWidth, chamferRadius: 0.115)
        glassGeometry.chamferSegmentCount = 24
        glassGeometry.materials = [glassMaterial()]
        let glass = SCNNode(geometry: glassGeometry)
        glass.name = "glassDeck"
        glass.position.y = 0.082
        deck.addChildNode(glass)

        // Keep a named state marker for scene tests, but never attach emissive
        // geometry. The real scale's black glass edge remains dark while measuring.
        let glow = SCNNode()
        glow.name = "measurementGlow"
        glow.opacity = 0
        glow.isHidden = true
        deck.addChildNode(glow)

        let displayGeometry = SCNBox(width: 0.47, height: 0.006, length: 0.255, chamferRadius: 0.035)
        displayGeometry.chamferSegmentCount = 12
        displayGeometry.materials = [material(ScalePlatformColor(white: 0.004, alpha: 1), roughness: 0.18)]
        let display = SCNNode(geometry: displayGeometry)
        display.name = "displayWindow"
        display.position = SCNVector3(0, 0.109, -0.46)
        deck.addChildNode(display)

        let textGeometry = SCNText(string: "0.0", extrusionDepth: 0.002)
        textGeometry.font = {
            #if canImport(UIKit)
            UIFont.monospacedDigitSystemFont(ofSize: 0.12, weight: .medium)
            #else
            NSFont.monospacedDigitSystemFont(ofSize: 0.12, weight: .medium)
            #endif
        }()
        textGeometry.flatness = 0.004
        let displayMaterial = SCNMaterial()
        displayMaterial.lightingModel = .constant
        displayMaterial.diffuse.contents = ScalePlatformColor(red: 0.20, green: 0.48, blue: 0.72, alpha: 1)
        displayMaterial.emission.contents = ScalePlatformColor(red: 0.04, green: 0.11, blue: 0.18, alpha: 1)
        textGeometry.materials = [displayMaterial]
        let text = SCNNode(geometry: textGeometry)
        text.name = "displayText"
        let bounds = textGeometry.boundingBox
        text.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2,
                                               (bounds.min.y + bounds.max.y) / 2, 0)
        text.eulerAngles.x = -.pi / 2
        text.position = SCNVector3(0, 0.116, -0.46)
        text.scale = SCNVector3(0.72, 0.72, 0.72)
        text.opacity = 0.26
        deck.addChildNode(text)

        let electrodePositions: [(Float, Float, Float)] = [
            (-0.43, -0.31, -.pi / 4), (0.43, -0.31, .pi / 4),
            (-0.43, 0.39, .pi / 4), (0.43, 0.39, -.pi / 4),
        ]
        let electrodes = electrodePositions.enumerated().map { index, pose in
            electrodeNode(index: index, x: pose.0, z: pose.1, angle: pose.2)
        }
        electrodes.forEach(deck.addChildNode)

        // Feet stay outside the moving deck group so the top visibly compresses when
        // a person steps on it, matching the side photo.
        let footMaterial = material(ScalePlatformColor(white: 0.025, alpha: 1), roughness: 0.9)
        let footPositions: [(Float, Float)] = [(-0.48, -0.48), (0.48, -0.48), (-0.48, 0.48), (0.48, 0.48)]
        for (index, position) in footPositions.enumerated() {
            let cylinder = SCNCylinder(radius: 0.12, height: 0.05)
            cylinder.radialSegmentCount = 40
            cylinder.materials = [footMaterial]
            let foot = SCNNode(geometry: cylinder)
            foot.name = "foot\(index)"
            foot.position = SCNVector3(position.0, -0.065, position.1)
            spinner.addChildNode(foot)
        }

        return Parts(pivot: pivot, spinner: spinner, deck: deck,
                     electrodes: electrodes, glow: glow, displayText: text)
    }

    final class Live {
        let scene = SCNScene()
        let pivot: SCNNode
        let spinner: SCNNode
        let camera: SCNNode
        private let deck: SCNNode
        private let electrodes: [SCNNode]
        private let glow: SCNNode
        private let displayText: SCNNode
        private let cameraTarget = SCNNode()
        private let presentation: Presentation
        private(set) var visualState: ScaleVisualState = .idle

        private let restCamera: SCNVector3
        private let measuringCamera: SCNVector3
        private var uprightAngle: CGFloat { presentation == .detail ? .pi / 2 : 0 }

        init(presentation: Presentation = .detail) {
            self.presentation = presentation
            switch presentation {
            case .card:
                restCamera = SCNVector3(0, 1.85, 2.75)
                measuringCamera = restCamera
            case .detail:
                restCamera = SCNVector3(0, 0.02, 3.55)
                measuringCamera = SCNVector3(0, 2.0, 3.6)
            }
            let parts = ScaleModel.makeNode()
            pivot = parts.pivot
            spinner = parts.spinner
            deck = parts.deck
            electrodes = parts.electrodes
            glow = parts.glow
            displayText = parts.displayText

            scene.background.contents = ScalePlatformColor.clear
            scene.rootNode.addChildNode(pivot)

            cameraTarget.position = SCNVector3Zero
            scene.rootNode.addChildNode(cameraTarget)
            let cameraObject = SCNCamera()
            cameraObject.fieldOfView = 29
            cameraObject.wantsHDR = false
            camera = SCNNode()
            camera.name = "camera"
            camera.camera = cameraObject
            camera.position = restCamera
            let look = SCNLookAtConstraint(target: cameraTarget)
            look.isGimbalLockEnabled = true
            camera.constraints = [look]
            scene.rootNode.addChildNode(camera)

            addLights()
            #if canImport(UIKit)
            pivot.eulerAngles.x = Float(uprightAngle)
            #else
            pivot.eulerAngles.x = uprightAngle
            #endif
            spinner.eulerAngles.y = presentation == .card ? -0.22 : 0
        }

        private func addLights() {
            func directional(intensity: CGFloat, color: ScalePlatformColor,
                             euler: SCNVector3) -> SCNNode {
                let light = SCNLight()
                light.type = .directional
                light.intensity = intensity
                light.color = color
                light.castsShadow = true
                light.shadowRadius = 7
                light.shadowColor = ScalePlatformColor(white: 0, alpha: 0.38)
                let node = SCNNode()
                node.light = light
                node.eulerAngles = euler
                return node
            }
            scene.rootNode.addChildNode(directional(intensity: 650, color: .white,
                                                    euler: SCNVector3(-0.75, 0.6, -0.35)))
            scene.rootNode.addChildNode(directional(
                intensity: 220,
                color: ScalePlatformColor(red: 0.58, green: 0.66, blue: 0.78, alpha: 1),
                euler: SCNVector3(-0.25, -1.7, 0.15)))
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 120
            ambient.color = ScalePlatformColor(white: 0.55, alpha: 1)
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

        }

        func playEntrance() {
            pivot.scale = SCNVector3(0.72, 0.72, 0.72)
            pivot.opacity = 0
            pivot.position.y = -0.16
            let rise = SCNAction.move(to: SCNVector3Zero, duration: 0.65)
            let grow = SCNAction.scale(to: 1, duration: 0.65)
            rise.timingMode = .easeOut
            grow.timingMode = .easeOut
            pivot.runAction(.group([rise, grow, .fadeIn(duration: 0.42)]))
        }

        func setDisplayText(_ text: String?) {
            guard let geometry = displayText.geometry as? SCNText else { return }
            geometry.string = text ?? "0.0"
            let bounds = geometry.boundingBox
            displayText.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2,
                                                          (bounds.min.y + bounds.max.y) / 2, 0)
            displayText.opacity = text == nil ? 0.26 : 1
        }

        func setVisualState(_ state: ScaleVisualState) {
            guard state != visualState else { return }
            visualState = state
            deck.removeAllActions()
            glow.removeAllActions()
            camera.removeAllActions()
            pivot.removeAction(forKey: "pressureTilt")
            electrodes.forEach { $0.removeAllActions() }

            switch state {
            case .idle:
                let faceUser = SCNAction.rotateTo(x: uprightAngle, y: 0, z: 0,
                                                  duration: 0.62,
                                                  usesShortestUnitArc: true)
                faceUser.timingMode = .easeInEaseOut
                pivot.runAction(faceUser, forKey: "pressureTilt")
                let lift = SCNAction.move(to: SCNVector3Zero, duration: 0.45)
                lift.timingMode = .easeOut
                deck.runAction(lift)
                camera.runAction(.move(to: restCamera, duration: 0.55))

            case .measuring:
                let layDown = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.78,
                                                 usesShortestUnitArc: true)
                layDown.timingMode = .easeInEaseOut
                pivot.runAction(layDown, forKey: "pressureTilt")
                let settle = SCNAction.move(to: SCNVector3(0, -0.028, 0), duration: 0.32)
                settle.timingMode = .easeOut
                deck.runAction(settle)
                let dolly = SCNAction.move(to: measuringCamera, duration: 0.55)
                dolly.timingMode = .easeInEaseOut
                camera.runAction(dolly)
                for (index, electrode) in electrodes.enumerated() {
                    electrode.runAction(.sequence([
                        .wait(duration: Double(index) * 0.11),
                        .repeatForever(.sequence([
                            .scale(to: 1.045, duration: 0.42),
                            .scale(to: 1.0, duration: 0.42),
                            .wait(duration: 0.42),
                        ])),
                    ]))
                }

            case .stable:
                let finishLayDown = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.24,
                                                       usesShortestUnitArc: true)
                finishLayDown.timingMode = .easeOut
                pivot.runAction(finishLayDown, forKey: "pressureTilt")
                let rest = SCNAction.move(to: SCNVector3(0, -0.012, 0), duration: 0.24)
                rest.timingMode = .easeOut
                deck.runAction(rest)
                camera.runAction(.move(to: measuringCamera, duration: 0.3))
                electrodes.forEach { electrode in
                    electrode.runAction(.sequence([
                        .scale(to: 1.055, duration: 0.16),
                        .scale(to: 1.0, duration: 0.32),
                    ]))
                }
            }
        }
    }
}
