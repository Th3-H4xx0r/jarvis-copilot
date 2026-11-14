import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The Jarvis loader (Copilot/UI/JcLoader.swift): its timing curves, and both
/// styles drawn at mid-animation frames to /tmp/ringshots (transparent PNGs) to
/// look at beside the approved SVG.
@MainActor
final class JcLoaderTests: XCTestCase {
    func testTheEasingMatchesCubicBezierEndpointsAndMidpoint() {
        XCTAssertEqual(JcLoaderGeometry.cubicBezier(0, 0.65, 0, 0.35, 1), 0)
        XCTAssertEqual(JcLoaderGeometry.cubicBezier(1, 0.65, 0, 0.35, 1), 1)
        // (.65, 0, .35, 1) is symmetric: half way in time is half way along.
        XCTAssertEqual(JcLoaderGeometry.cubicBezier(0.5, 0.65, 0, 0.35, 1), 0.5, accuracy: 0.001)
        XCTAssertLessThan(JcLoaderGeometry.cubicBezier(0.2, 0.65, 0, 0.35, 1), 0.2)   // eases in
    }

    func testDrawRingsFollowTheirKeyTimes() throws {
        // Ring A: drawing at the start, full on its hold, erasing at the end.
        XCTAssertEqual(try XCTUnwrap(JcLoaderDraw.trim(at: 0, start: 0, full: 0.42, hold: 0.6)).1, 0)
        XCTAssertEqual(try XCTUnwrap(JcLoaderDraw.trim(at: 0.5, start: 0, full: 0.42, hold: 0.6)).1, 1)
        let erasing = try XCTUnwrap(JcLoaderDraw.trim(at: 0.8, start: 0, full: 0.42, hold: 0.6))
        XCTAssertEqual(erasing.1, 1)
        XCTAssertEqual(erasing.0, 0.5, accuracy: 0.001)
        // Ring B: hidden until 12%.
        XCTAssertNil(JcLoaderDraw.trim(at: 0.1, start: 0.12, full: 0.5, hold: 0.66))
        XCTAssertNotNil(JcLoaderDraw.trim(at: 0.2, start: 0.12, full: 0.5, hold: 0.66))
    }

    func testTraceSegmentWrapsAcrossThePathStart() {
        let ring = JcLoaderGeometry.ringA
        let wrapped = JcLoaderGeometry.segment(of: ring, start: 0.9, length: 0.26)
        let straight = JcLoaderGeometry.segment(of: ring, start: 0.3, length: 0.26)
        // The wrapped segment is the same length (two pieces), so its bounds are not empty.
        XCTAssertFalse(wrapped.isEmpty)
        XCTAssertFalse(straight.isEmpty)
    }

    func testTheLoaderRendersInBothStyles() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RING_SNAPSHOT_DIR"] ?? "/tmp/ringshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let frames: [(String, JcLoaderStyle, Double)] = [
            ("trace-0.30", .trace, 0.30), ("trace-0.85", .trace, 0.85),
            ("draw-0.25", .draw, 0.25), ("draw-0.55", .draw, 0.55), ("draw-0.80", .draw, 0.80),
        ]
        for (name, style, phase) in frames {
            let renderer = ImageRenderer(content: JcLoaderFrame(size: 24, style: style, phase: phase)
                .foregroundStyle(.white))
            renderer.scale = 16
            let image = try XCTUnwrap(renderer.uiImage, name)
            try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("jcloader-\(name).png"))
        }
        // A strip of sizes and colours on the app background, as they sit in the app.
        let strip = HStack(spacing: 18) {
            JcLoaderFrame(size: 12, style: .trace, phase: 0.3).foregroundStyle(JcTheme.muted)
            JcLoaderFrame(size: 16, style: .trace, phase: 0.3).foregroundStyle(JcTheme.accent)
            JcLoaderFrame(size: 20, style: .trace, phase: 0.3).foregroundStyle(JcTheme.text)
            JcLoaderFrame(size: 28, style: .trace, phase: 0.6).foregroundStyle(Color(red: 0.2, green: 0.83, blue: 0.6))
            JcLoaderFrame(size: 28, style: .draw, phase: 0.3).foregroundStyle(JcTheme.text)
            JcLoader("Loading…")
        }
        .padding(20)
        try RenderHarness.write(strip, size: CGSize(width: 360, height: 110), name: "jcloader-strip", settle: 0.8)
    }
}
