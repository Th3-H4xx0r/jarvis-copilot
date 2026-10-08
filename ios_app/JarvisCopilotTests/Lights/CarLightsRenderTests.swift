import Metal
import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The cabin from above with the lamps lit; frames to `JC_RENDER_DIR` for judging.
@MainActor
final class CarLightsRenderTests: XCTestCase {
    private func render(_ scene: CarLightsScene, size: CGSize) throws -> (UIImage, SCNRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene.live.scene
        renderer.pointOfView = scene.live.camera
        _ = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return (renderer.snapshot(atTime: 1, with: size, antialiasingMode: .multisampling4X), renderer)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["JC_RENDER_DIR"] else { return }
        let onBlack = UIGraphicsImageRenderer(size: image.size).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: image.size)); image.draw(at: .zero)
        }
        try? onBlack.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testEveryLampIsOnScreenAndTappable() throws {
        let scene = CarLightsScene()
        var looks: [String: CarLightsScene.Look] = [:]
        for (i, lamp) in scene.layout.lamps.enumerated() {
            let preset = MelkColor.presets[i % MelkColor.presets.count].color
            looks[lamp.id] = i == 3 ? .cycling : .solid(preset, brightness: 90)
        }
        scene.show(looks)
        let size = CGSize(width: 390, height: 430)
        let (image, renderer) = try render(scene, size: size)
        write(image, "lights-cutaway.png")
        for lamp in scene.layout.lamps {
            let p = try XCTUnwrap(scene.screenPoint(of: lamp.id, in: renderer))
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8).contains(p), "\(lamp.id) off screen at \(p)")
        }
        XCTAssertTrue(scene.isAnimating)
        scene.show([:])
        write(try render(scene, size: size).0, "lights-cutaway-unpaired.png")
    }

    func testCardAndControlsRender() throws {
        try RenderHarness.write(VStack(spacing: 14) {
            CarLightsCard(looks: [:], status: .init(text: "Not paired", connected: false), paired: false, lampCount: 11)
            CarLightsCard(looks: ["dash": .solid(MelkColor(r: 0, g: 60, b: 255), brightness: 80)],
                          status: .init(text: "Blue · 80 %", connected: true), paired: true, lampCount: 11)
        }.padding(16), size: CGSize(width: 402, height: 440), name: "lights-cards.png")
    }
}
