import Metal
import SceneKit
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Renders the baked Camry offscreen. With `JC_RENDER_DIR` set the frames are written out — the
/// car is judged from these on the app's black background before it goes on a phone.
@MainActor
final class CarModelRenderTests: XCTestCase {
    private func render(_ live: CarModel.Live, width: CGFloat, height: CGFloat) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        let frame = CGSize(width: width, height: height)
        _ = renderer.snapshot(atTime: 0, with: frame, antialiasingMode: .multisampling4X)
        return renderer.snapshot(atTime: 2, with: frame, antialiasingMode: .multisampling4X)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["JC_RENDER_DIR"],
              let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// Composited on the app's black, the way the card shows it.
    private func onBlack(_ image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: image.size).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
    }

    /// Mean blue minus mean red over the drawn pixels: Dark Cosmos must read blue, not grey.
    private func blueLead(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var lead = 0.0, n = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 && max(bytes[i], bytes[i + 1], bytes[i + 2]) > 20 {
            lead += Double(bytes[i + 2]) - Double(bytes[i])
            n += 1
        }
        return n > 0 ? lead / n : 0
    }

    private func bluePixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if b > r + 12, b > g, bytes[i + 3] > 200 { count += 1 }
        }
        return count
    }

    func testTheBundledCarLoadsWithItsParts() throws {
        let mesh = try XCTUnwrap(CarModel.bundled, "Camry.bin missing from the app bundle")
        XCTAssertTrue(mesh.parts.contains { $0.slot == .paint })
        XCTAssertEqual(mesh.max.z - mesh.min.z, 4.915, accuracy: 0.05, "a Camry is 4.9 m long")
        XCTAssertEqual(mesh.min.y, 0, accuracy: 0.02, "wheels on the ground")
    }

    func testACorruptFileLoadsNothing() {
        XCTAssertNil(CarModel.mesh(from: Data("JCCR".utf8)))
        XCTAssertNil(CarModel.mesh(from: Data(repeating: 0, count: 64)))
        var truncated = try? Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "Camry", withExtension: "bin")))
        truncated = truncated?.prefix(4096)
        XCTAssertNil(truncated.flatMap(CarModel.mesh(from:)))
        XCTAssertFalse(CarModel.Live(mesh: nil).hasModel)
    }

    func testAnIndexPastTheVerticesIsRejectedAndSlicesRead() throws {
        // One slot, three vertices, one triangle whose last index is 3 (out of range).
        func file(lastIndex: UInt32) -> Data {
            var d = Data("JCCR".utf8)
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func f32(_ v: Float) { u32(v.bitPattern) }
            u32(1); u32(1); (0..<6).forEach { _ in f32(0) }
            u32(0); u32(3); u32(3)
            (0..<18).forEach { _ in f32(0) }
            u32(0); u32(1); u32(lastIndex)
            return d
        }
        XCTAssertNil(CarModel.mesh(from: file(lastIndex: 3)))
        XCTAssertNotNil(CarModel.mesh(from: file(lastIndex: 2)))
        let padded = Data([0, 0, 0]) + file(lastIndex: 2)
        XCTAssertNotNil(CarModel.mesh(from: padded.dropFirst(3)), "a Data slice reads from its own start")
    }

    func testThePaintReadsDarkCosmosBlue() throws {
        let card = try render(CarModel.Live(presentation: .card, spin: false), width: 472, height: 336)
        write(onBlack(card), "car-card.png")
        XCTAssertGreaterThan(blueLead(card), 3, "the body should read blue, not grey (neutral grey is ~0)")
        XCTAssertGreaterThan(bluePixels(card), 300)

        let lit = CarModel.Live(presentation: .card, spin: false)
        lit.setLit(true)
        write(onBlack(try render(lit, width: 472, height: 336)), "car-card-lit.png")
        write(onBlack(try render(CarModel.Live(presentation: .hero, spin: false), width: 780, height: 440)), "car-hero.png")
        // Around the car, for judging every side.
        for (i, yaw) in [Float(0), .pi / 2, .pi, -.pi / 2].enumerated() {
            let live = CarModel.Live(presentation: .hero, spin: false)
            live.spinner.eulerAngles.y = yaw
            write(onBlack(try render(live, width: 780, height: 440)), "car-turn-\(i).png")
        }
    }

    func testCardAndPageRender() throws {
        try RenderHarness.write(VStack(spacing: 14) {
            CarCard(name: "Camry", subtitle: "2026 Toyota Camry SE", inCar: false, lastSeen: Date().addingTimeInterval(-7200))
            CarCard(name: "Camry", subtitle: "2026 Toyota Camry SE", inCar: true, lastSeen: nil, pendingUploads: 3)
            WearableControlsSection(controls: []) { _, _ in }
        }.padding(16), size: CGSize(width: 402, height: 640), name: "car-cards.png")

        let recorder = ControlRecorder()
        try RenderHarness.write(WearableControlsSection(controls: [
            recorder.control("lights.power", .toggle(isOn: true)),
            recorder.control("lights.flash", .button),
            recorder.control("lights.level", .level(value: 60, range: 0...100, step: 5, unit: "%")),
            recorder.control("lights.mode", .choice(selected: "calm", options: [.init(id: "calm", title: "Calm")])),
        ]) { _, _ in }.padding(.vertical, 16), size: CGSize(width: 402, height: 420), name: "car-controls.png")
    }

    /// The page's car glides to the top view and into the cabin: render each stage (with
    /// `JC_RENDER_DIR`, the PNGs are written for a look before it goes on a phone).
    func testHeroGoesToTheTopViewAndIntoTheCabin() throws {
        let live = CarModel.Live(presentation: .hero, spin: false, canSlice: true)
        guard live.hasModel else { throw XCTSkip("no bundled model") }
        let hero = try render(live, width: 402, height: 230)
        write(onBlack(hero), "stage-hero.png")
        // The Face ID approval card's resting pose, centred in its 334 × 200 frame.
        let card = CarModel.Live(presentation: .approval, spin: false)
        write(onBlack(try render(card, width: 334, height: 200)), "approval-car.png")
        live.go(to: .top, animated: false)
        XCTAssertEqual(live.stage, .top)
        let top = try render(live, width: 402, height: 400)
        write(onBlack(top), "stage-top.png")
        live.go(to: .cabin, animated: false)
        let cabin = try render(live, width: 402, height: 460)
        write(onBlack(cabin), "stage-cabin.png")
        live.go(to: .hero, animated: false)
        XCTAssertEqual(live.stage, .hero)
    }

    /// The approval card's car waits nearly head-on, then turns into its rest pose and stays there.
    func testTheApprovalCarTurnsIntoItsPose() {
        let car = CarModel.Live(presentation: .approval, spin: false, mesh: nil)
        let rest = CarModel.Presentation.approval.restYaw
        XCTAssertEqual(car.spinner.eulerAngles.y, rest, accuracy: 1e-4)
        car.readyEntrance()
        XCTAssertEqual(car.spinner.eulerAngles.y, rest + CarModel.Live.entranceTurn, accuracy: 1e-4)
        car.enter()
        XCTAssertEqual(car.spinner.eulerAngles.y, rest, accuracy: 1e-4)
        XCTAssertNil(car.spinner.action(forKey: "spin"))
    }

    /// Front at the top, the driver's (left) side on the left, the car centred.
    func testTopViewLabelsLandOnTheRightWheels() {
        let marks = Landmarks(mesh: CarModel.bundled)
        let size = CGSize(width: 402, height: 400)
        func at(_ key: String) -> CGPoint {
            CarModel.Live.topViewPoint(marks.wheels[key]!, in: size, height: CarModel.Live.topHeight, centreZ: marks.centreZ)
        }
        XCTAssertLessThan(at("fl").x, size.width / 2)
        XCTAssertGreaterThan(at("fr").x, size.width / 2)
        XCTAssertLessThan(at("fl").y, at("rl").y, "front wheels above the rear ones")
        XCTAssertEqual(at("fl").y, at("fr").y, accuracy: 0.5)
        XCTAssertEqual(at("fl").x + at("fr").x, size.width, accuracy: 1, "symmetric about the middle")
        for key in ["fl", "fr", "rl", "rr"] {
            let p = at(key)
            XCTAssertTrue((0...size.width).contains(p.x) && (0...size.height).contains(p.y), key)
        }
    }
}

@MainActor
final class CarTurntableTests: XCTestCase {
    func testADragTurnsOnlyAboutTheVerticalAxisThenItSpinsAgain() {
        let live = CarModel.Live(presentation: .hero, spin: true, mesh: nil)
        live.beginTurn()
        XCTAssertNil(live.spinner.action(forKey: "spin"), "held still while dragging")
        let start = live.spinner.eulerAngles
        live.turn(by: 100)
        XCTAssertEqual(live.spinner.eulerAngles.y - start.y, 100 * CarModel.Live.turnRate, accuracy: 1e-5)
        XCTAssertEqual(live.spinner.eulerAngles.x, start.x)
        XCTAssertEqual(live.spinner.eulerAngles.z, start.z)
        live.endTurn(velocity: 800)
        XCTAssertNotNil(live.spinner.action(forKey: "spin"), "coasts, then keeps turning")
    }

}
