import Metal
import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The cabin from above with the lamps lit; frames to `JC_RENDER_DIR` for judging.
@MainActor
final class CarLightsRenderTests: XCTestCase {
    private func renderer(_ scene: CarLightsScene) throws -> SCNRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene.live.scene
        renderer.pointOfView = scene.live.camera
        return renderer
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["JC_RENDER_DIR"] else { return }
        let onBlack = UIGraphicsImageRenderer(size: image.size).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: image.size)); image.draw(at: .zero)
        }
        try? onBlack.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testEveryLampIsOnScreen() throws {
        let scene = CarLightsScene()
        scene.show(CarLightLayout.bundled)
        scene.show(.solid(MelkColor(r: 120, g: 40, b: 255), brightness: 90))
        let size = CGSize(width: 390, height: 430)
        let r = try renderer(scene)
        _ = r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        write(r.snapshot(atTime: 1, with: size, antialiasingMode: .multisampling4X), "lights-cutaway.png")
        for lamp in scene.layout.lamps {
            let p = try XCTUnwrap(scene.screenPoint(of: lamp.id, in: r))
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8).contains(p), "\(lamp.id) off screen at \(p)")
        }
        scene.show(.unavailable)
        scene.select(scene.layout.lamps.first?.id)
        write(r.snapshot(atTime: 2, with: size, antialiasingMode: .multisampling4X), "lights-cutaway-unavailable-selected.png")
    }

    func testEditingTheLayoutRebuildsTheLamps() throws {
        let scene = CarLightsScene()
        scene.show(CarLightLayout(version: 1, lamps: [.spot(id: "a", name: "A", at: SIMD3(0.3, 0.4, 0.5))]))
        let r = try renderer(scene)
        XCTAssertNotNil(scene.screenPoint(of: "a", in: r))
        scene.show(CarLightLayout(version: 1, lamps: [.strip(id: "b", name: "B", from: SIMD3(0, 0.5, 0), to: SIMD3(0, 0.5, 1))]))
        XCTAssertNil(scene.screenPoint(of: "a", in: r), "a removed lamp is gone from the scene")
        XCTAssertNotNil(scene.screenPoint(of: "b", in: r))
    }

    func testATapOnTheCabinFindsItsSurface() throws {
        let scene = CarLightsScene()
        scene.show(CarLightLayout.bundled)
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 430))
        view.scene = scene.live.scene
        view.pointOfView = scene.live.camera
        view.layoutIfNeeded()
        // The middle of the cabin (between the front seats) is cabin; the far corner is not.
        let middle = view.projectPoint(scene.live.spinner.convertPosition(SCNVector3(0, 0.5, 0.1), to: nil))
        let p = try XCTUnwrap(scene.cabinPoint(at: CGPoint(x: CGFloat(middle.x), y: CGFloat(middle.y)), in: view))
        XCTAssertLessThanOrEqual(p.y, CarModel.beltHeight + 0.05)
        XCTAssertLessThan(abs(p.x), 1.0)
        XCTAssertNil(scene.cabinPoint(at: CGPoint(x: 2, y: 2), in: view))
    }

    func testCardRenders() throws {
        try RenderHarness.write(VStack(spacing: 14) {
            CarLightsCard(layout: .bundled, look: .unavailable, status: .init(text: "Not paired", connected: false), paired: false)
            CarLightsCard(layout: .bundled, look: .solid(MelkColor(r: 0, g: 60, b: 255), brightness: 80),
                          status: .init(text: "Blue · 80 %", connected: true), paired: true)
        }.padding(16), size: CGSize(width: 402, height: 440), name: "lights-cards.png")
        let recorder = ControlRecorder()
        try RenderHarness.write(WearableControlsSection(controls: [
            recorder.control("lights.power", .toggle(isOn: false)),
            recorder.control("lights.brightness", .level(value: 65, range: 0...100, step: 5, unit: "%")),
            recorder.control("lights.color", .choice(selected: "", options: [.init(id: "red", title: "Red")])),
            recorder.control("lights.effect", .choice(selected: "0", options: [.init(id: "0", title: "Auto Play")])),
        ]) { _, _ in }.padding(.vertical, 16), size: CGSize(width: 402, height: 420), name: "car-controls-connected.png")
        try RenderHarness.write(WearableControlsSection(controls: [
            recorder.control("lights.power", .toggle(isOn: false), enabled: false),
            recorder.control("lights.brightness", .level(value: 65, range: 0...100, step: 5, unit: "%"), enabled: false),
        ]) { _, _ in }.padding(.vertical, 16), size: CGSize(width: 402, height: 260), name: "car-controls-unavailable.png")
    }
}
