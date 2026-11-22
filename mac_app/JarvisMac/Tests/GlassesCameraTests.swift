import CoreImage
import CoreVideo
import SystemExtensions
import XCTest
@testable import Jarvis

/// The Jarvis Glasses camera: the frame maths the app and the extension share (fit, letterbox,
/// the placeholder card), the app's frame conversion, when the Mac asks the phone for video,
/// and what Settings says. The extension itself only runs once macOS loads it (Developer ID).
final class GlassesCameraTests: XCTestCase {

    // MARK: Spec

    func testTheCameraOffersPortraitFirstThenLandscapeAt30fps() {
        XCTAssertEqual(GlassesCameraSpec.formats, [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)])
        XCTAssertEqual(GlassesCameraSpec.sinkSize, GlassesCameraSpec.portrait)
        XCTAssertEqual(GlassesCameraSpec.fps, 30)
        XCTAssertEqual(GlassesCameraSpec.name, "Jarvis Glasses")
    }

    func testTheClientsPropertyNameAndSelectorAgree() {
        XCTAssertEqual(GlassesCameraSpec.clientsSelector, 0x6A67_636C)   // 'jgcl'
        XCTAssertTrue(GlassesCameraSpec.clientsPropertyName.hasPrefix("4cc_jgcl_"))
        XCTAssertTrue(GlassesCameraSpec.extensionBundleID.hasPrefix(GlassesCameraSpec.appBundleID + "."))
    }

    // MARK: Geometry

    func testPortraitFitsIntoLandscapeAsACentredEvenPillar() {
        let r = GlassesFrameGeometry.fit(CGSize(width: 720, height: 1280), in: CGSize(width: 1280, height: 720))
        XCTAssertEqual(r, CGRect(x: 438, y: 0, width: 404, height: 720))
    }

    func testSameAspectFillsAndLandscapeLetterboxesIntoPortrait() {
        XCTAssertEqual(GlassesFrameGeometry.fit(CGSize(width: 360, height: 640), in: CGSize(width: 720, height: 1280)),
                       CGRect(x: 0, y: 0, width: 720, height: 1280))
        let r = GlassesFrameGeometry.fit(CGSize(width: 1280, height: 720), in: CGSize(width: 720, height: 1280))
        XCTAssertEqual(r.width, 720)
        XCTAssertEqual(r.height, 404)
        XCTAssertEqual(r.minY, 438)
        XCTAssertEqual(GlassesFrameGeometry.fit(.zero, in: CGSize(width: 720, height: 1280)),
                       CGRect(x: 0, y: 0, width: 720, height: 1280))
    }

    // MARK: Drawing (vImage, the extension's path)

    func testRenderLetterboxesWithBlackBarsAndThePictureInTheMiddle() throws {
        let red = try buffer(720, 1280, fill: (0, 0, 255, 255))
        let out = try buffer(1280, 720)
        XCTAssertTrue(GlassesFrameRenderer.render(red, into: out))
        XCTAssertEqual(pixel(out, 10, 360), [0, 0, 0, 255])
        XCTAssertEqual(pixel(out, 1270, 360), [0, 0, 0, 255])
        let middle = pixel(out, 640, 360)
        XCTAssertEqual(middle[2], 255)
        XCTAssertEqual(middle[0], 0)
    }

    func testRenderCopiesASameSizeFrameAndRefusesOtherFormats() throws {
        let green = try buffer(720, 1280, fill: (0, 255, 0, 255))
        let out = try buffer(720, 1280)
        XCTAssertTrue(GlassesFrameRenderer.render(green, into: out))
        XCTAssertEqual(pixel(out, 0, 0), [0, 255, 0, 255])
        XCTAssertEqual(pixel(out, 719, 1279), [0, 255, 0, 255])
        var yuv: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &yuv)
        XCTAssertFalse(GlassesFrameRenderer.render(try XCTUnwrap(yuv), into: out))
    }

    func testThePlaceholderDrawsWhiteOnBlackInBothFormats() throws {
        for size in GlassesCameraSpec.formats {
            let card = try buffer(Int(size.width), Int(size.height), fill: (40, 40, 40, 255))
            GlassesPlaceholder.render(into: card)
            XCTAssertEqual(pixel(card, 1, 1), [0, 0, 0, 255], "corner of \(size)")
            XCTAssertGreaterThan(brightPixels(card), 200, "the glasses and the words in \(size)")
        }
    }

    // MARK: The app's frame conversion (Core Image / vImage)

    func testConverterFitsAnyPictureIntoTheSinkSize() throws {
        let converter = GlassesFrameConverter()
        let out = try buffer(720, 1280)
        let wide = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        converter.render(wide, into: out)
        XCTAssertEqual(pixel(out, 360, 20), [0, 0, 0, 255])        // bar above
        let centre = pixel(out, 360, 640)
        XCTAssertGreaterThan(centre[0], 200)                       // blue, in BGRA
        XCTAssertLessThan(centre[2], 40)
    }

    func testI420PlanesBecomeBGRA() throws {
        // Pure red in BT.601 video range: Y 81, Cb 90, Cr 240.
        let w = 8, h = 8
        let y = [UInt8](repeating: 81, count: w * h)
        let u = [UInt8](repeating: 90, count: w * h / 4)
        let v = [UInt8](repeating: 240, count: w * h / 4)
        let out = try XCTUnwrap(y.withUnsafeBufferPointer { yp in
            u.withUnsafeBufferPointer { up in
                v.withUnsafeBufferPointer { vp in
                    GlassesFrameConverter.bgra(width: w, height: h, y: (yp.baseAddress!, w),
                                               u: (up.baseAddress!, w / 2), v: (vp.baseAddress!, w / 2))
                }
            }
        })
        let p = pixel(out, 4, 4)
        XCTAssertGreaterThan(p[2], 220)   // R
        XCTAssertLessThan(p[1], 40)       // G
        XCTAssertLessThan(p[0], 40)       // B
        XCTAssertEqual(p[3], 255)
    }

    // MARK: When the Mac asks for video

    func testTheMacAsksWhileAnAppUsesTheCameraAndLingersAfter() {
        var demand = GlassesCameraDemand()
        let t0 = Date()
        XCTAssertFalse(demand.wanted(installed: true, clients: 0, now: t0))
        XCTAssertTrue(demand.wanted(installed: true, clients: 1, now: t0))
        XCTAssertTrue(demand.wanted(installed: true, clients: 0, now: t0.addingTimeInterval(5)))
        XCTAssertFalse(demand.wanted(installed: true, clients: 0, now: t0.addingTimeInterval(GlassesCameraDemand.linger + 1)))
    }

    func testNoCameraNeverAsksAndAnExtensionThatCantSayAlwaysDoes() {
        var demand = GlassesCameraDemand()
        let t0 = Date()
        XCTAssertTrue(demand.wanted(installed: true, clients: 2, now: t0))
        XCTAssertFalse(demand.wanted(installed: false, clients: 2, now: t0))
        XCTAssertFalse(demand.wanted(installed: true, clients: 0, now: t0.addingTimeInterval(1)), "uninstall forgets the linger")
        XCTAssertTrue(demand.wanted(installed: true, clients: nil, now: t0.addingTimeInterval(2)))
    }

    // MARK: What Settings says

    func testPhasesFollowTheCameraTheServerAndThePhone() {
        typealias P = GlassesCameraPhase
        XCTAssertEqual(P.of(installed: false, wanted: true, online: true, asked: true, peer: .connected, frameFresh: true), .notInstalled)
        XCTAssertEqual(P.of(installed: true, wanted: false, online: true, asked: false, peer: nil, frameFresh: false), .idle)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: false, asked: false, peer: nil, frameFresh: false), .offline)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: true, asked: false, peer: nil, frameFresh: false), .connecting)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: true, asked: true, peer: nil, frameFresh: false), .waitingForPhone)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: true, asked: true, peer: .failed, frameFresh: false), .waitingForPhone)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: true, asked: true, peer: .connected, frameFresh: false), .connected)
        XCTAssertEqual(P.of(installed: true, wanted: true, online: true, asked: true, peer: .connected, frameFresh: true), .live)
        XCTAssertTrue(P.waitingForPhone.text.contains("Send to Mac camera"))
    }

    func testInstallErrorsSayWhatToDo() {
        func code(_ c: OSSystemExtensionError.Code) -> Error { NSError(domain: OSSystemExtensionErrorDomain, code: c.rawValue) }
        XCTAssertTrue(GlassesCameraInstaller.explain(code(.unsupportedParentBundleLocation)).contains("/Applications"))
        XCTAssertTrue(GlassesCameraInstaller.explain(code(.missingEntitlement)).contains("Developer ID"))
        XCTAssertTrue(GlassesCameraInstaller.explain(code(.authorizationRequired)).contains("Camera Extensions"))
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "plain words"])
        XCTAssertEqual(GlassesCameraInstaller.explain(other), "plain words")
    }

    // MARK: Helpers

    private func buffer(_ w: Int, _ h: Int, fill: (UInt8, UInt8, UInt8, UInt8)? = nil) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &out)
        let pixels = try XCTUnwrap(out)
        if let fill {
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * row + x * 4
                    p[0] = fill.0; p[1] = fill.1; p[2] = fill.2; p[3] = fill.3
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
        return pixels
    }

    /// [B, G, R, A] at (x, y).
    private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return [p[0], p[1], p[2], p[3]]
    }

    private func brightPixels(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var n = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) where base[y * row + x * 4 + 2] > 200 { n += 1 }
        }
        return n
    }
}
