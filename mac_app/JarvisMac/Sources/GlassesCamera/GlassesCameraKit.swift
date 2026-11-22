import Accelerate
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// The "Jarvis Glasses" camera: what the Mac app and its camera extension (the
/// JarvisGlassesCamera CoreMediaIO system extension) must agree on, and the frame maths
/// both sides run. Compiled into both targets, so it uses no AppKit and no WebRTC.
///
/// The picture's path: the iPhone sends the glasses' live video over WebRTC → the app
/// (GlassesCameraService) draws each frame into a 720×1280 BGRA buffer → the extension's
/// sink stream → the extension's source stream, which FaceTime, Zoom and Meet read. With
/// no fresh frame the extension draws `GlassesPlaceholder` itself.
enum GlassesCameraSpec {
    static let name = "Jarvis Glasses"
    static let manufacturer = "Jarvis"
    static let model = "Meta glasses"
    static let appBundleID = "com.jarviscopilot.mac"
    static let extensionBundleID = "com.jarviscopilot.mac.glassescamera"
    /// Fixed, so FaceTime and Zoom remember the camera across launches and reinstalls.
    static let deviceID = UUID(uuidString: "6A1E5B9C-3F2D-4C8A-9E71-2B0D4F6A8C31")!
    static let sourceStreamID = UUID(uuidString: "0B7D9E42-58A1-4F63-8C2E-71D5A3B9F604")!
    static let sinkStreamID = UUID(uuidString: "C4E2A817-9D3B-4A56-B0F1-5E8C26D47A93")!

    /// The glasses' live format (portrait). The camera also offers it letterboxed into
    /// landscape for apps that only take landscape (Chrome's Meet usually picks that one).
    static let portrait = CGSize(width: 720, height: 1280)
    static let landscape = CGSize(width: 1280, height: 720)
    /// What the camera offers, in order (index = the stream's format index).
    static let formats = [portrait, landscape]
    static let fps: Int32 = 30
    /// The app always feeds the sink at the glasses' own size.
    static var sinkSize: CGSize { portrait }
    /// No new frame from the app for this long: the extension shows the placeholder
    /// (a short network stall freezes the picture rather than flashing the card).
    static let staleAfter: TimeInterval = 2.0

    /// How many apps are using the camera right now, published by the extension on its
    /// source stream as a custom property (text, e.g. "1"). The app reads it with this
    /// selector to know when to ask the iPhone for video.
    static let clientsSelector: FourCharCode = fourCC("jgcl")
    /// The same property as CoreMediaIO extensions name custom properties.
    static let clientsPropertyName = "4cc_jgcl_glob_0000"

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

/// Fitting one picture inside another (aspect kept, centred, whole and even pixels).
enum GlassesFrameGeometry {
    static func fit(_ source: CGSize, in target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width >= 2, target.height >= 2 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = min(target.width / source.width, target.height / source.height)
        func even(_ v: CGFloat, max limit: CGFloat) -> CGFloat {
            min(limit, max(2, (v.rounded() / 2).rounded(.down) * 2))
        }
        let w = even(source.width * scale, max: target.width)
        let h = even(source.height * scale, max: target.height)
        return CGRect(x: ((target.width - w) / 2).rounded(.down), y: ((target.height - h) / 2).rounded(.down),
                      width: w, height: h)
    }

    static func size(of buffer: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }
}

/// CPU drawing between 32BGRA buffers (vImage): the extension letterboxes the app's
/// portrait frames into the landscape format with it.
enum GlassesFrameRenderer {
    static let black: [UInt8] = [0, 0, 0, 255]   // B, G, R, A in memory

    static func isBGRA(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
    }

    /// Opaque black, all of it.
    static func fillBlack(_ buffer: CVPixelBuffer) {
        guard isBGRA(buffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var dst = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
                                rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        _ = vImageBufferFill_ARGB8888(&dst, black, vImage_Flags(kvImageNoFlags))
    }

    /// `source` fitted and centred in `dest`, black around it. False if either isn't 32BGRA.
    @discardableResult
    static func render(_ source: CVPixelBuffer, into dest: CVPixelBuffer) -> Bool {
        guard isBGRA(source), isBGRA(dest) else { return false }
        fillBlack(dest)
        let rect = GlassesFrameGeometry.fit(GlassesFrameGeometry.size(of: source), in: GlassesFrameGeometry.size(of: dest))
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source), let dstBase = CVPixelBufferGetBaseAddress(dest) else {
            return false
        }
        let dstRow = CVPixelBufferGetBytesPerRow(dest)
        var src = vImage_Buffer(data: srcBase, height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(source)),
                                rowBytes: CVPixelBufferGetBytesPerRow(source))
        var dst = vImage_Buffer(data: dstBase + Int(rect.minY) * dstRow + Int(rect.minX) * 4,
                                height: vImagePixelCount(rect.height), width: vImagePixelCount(rect.width),
                                rowBytes: dstRow)
        if src.width == dst.width, src.height == dst.height {
            return vImageCopyBuffer(&src, &dst, 4, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}

/// The card the camera shows while no video arrives: black, a pair of glasses, what's
/// wrong and what to do. Drawn by the extension (so it shows even with Jarvis closed).
enum GlassesPlaceholder {
    static let title = "Glasses not streaming"
    static let detail = "Start live on your iPhone and turn on Send to Mac camera."

    /// Draws the card into a 32BGRA buffer of any size.
    static func render(into buffer: CVPixelBuffer, title: String = title, detail: String = detail) {
        guard GlassesFrameRenderer.isBGRA(buffer) else { return }
        GlassesFrameRenderer.fillBlack(buffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let width = CGFloat(w), height = CGFloat(h)
        let unit = min(width, height)
        // CoreGraphics' origin is bottom-left: lay out from the top down by flipping y.
        func fromTop(_ y: CGFloat) -> CGFloat { height - y }

        // The glasses: two rounded lenses and a bridge, outlined in white.
        let lens = CGSize(width: unit * 0.17, height: unit * 0.12)
        let gap = unit * 0.05
        let glyphTop = height * 0.5 - unit * 0.20
        let left = CGRect(x: width / 2 - gap / 2 - lens.width, y: fromTop(glyphTop + lens.height),
                          width: lens.width, height: lens.height)
        let right = left.offsetBy(dx: lens.width + gap, dy: 0)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(max(2, unit * 0.008))
        ctx.addPath(CGPath(roundedRect: left, cornerWidth: lens.height * 0.35, cornerHeight: lens.height * 0.35, transform: nil))
        ctx.addPath(CGPath(roundedRect: right, cornerWidth: lens.height * 0.35, cornerHeight: lens.height * 0.35, transform: nil))
        ctx.move(to: CGPoint(x: left.maxX, y: left.maxY - lens.height * 0.25))
        ctx.addQuadCurve(to: CGPoint(x: right.minX, y: right.maxY - lens.height * 0.25),
                         control: CGPoint(x: width / 2, y: left.maxY - lens.height * 0.05))
        ctx.strokePath()

        // The words under it, centred and wrapped.
        let textTop = glyphTop + lens.height + unit * 0.07
        let box = CGRect(x: width * 0.12, y: 0, width: width * 0.76, height: fromTop(textTop))
        let text = NSMutableAttributedString()
        text.append(attributed(title + "\n", size: unit * 0.05, emphasized: true, gray: 1))
        text.append(attributed(detail, size: unit * 0.032, emphasized: false, gray: 0.62))
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: text.length), CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, ctx)

        // The camera's name, small, at the bottom.
        let label = NSMutableAttributedString(attributedString: attributed(GlassesCameraSpec.name, size: unit * 0.026,
                                                                            emphasized: true, gray: 0.45))
        let labelSetter = CTFramesetterCreateWithAttributedString(label)
        let labelBox = CGRect(x: 0, y: unit * 0.05, width: width, height: unit * 0.06)
        CTFrameDraw(CTFramesetterCreateFrame(labelSetter, CFRange(location: 0, length: label.length),
                                             CGPath(rect: labelBox, transform: nil), nil), ctx)
    }

    private static func attributed(_ string: String, size: CGFloat, emphasized: Bool, gray: CGFloat) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(emphasized ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var alignment = CTTextAlignment.center
        var spacing = size * 0.35
        let style = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &spacing) { s in
                CTParagraphStyleCreate([
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: s.baseAddress!),
                ], 2)
            }
        }
        return NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
    }
}

/// Buffers and sample buffers in the camera's one pixel format (32BGRA, IOSurface-backed so
/// they cross from the app to the extension and on to FaceTime without a copy).
enum GlassesCameraBuffers {
    static func pool(_ size: CGSize, minimum: Int = 4) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: minimum] as CFDictionary,
                                attrs as CFDictionary, &pool)
        return pool
    }

    static func buffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }

    static func format(_ size: CGSize) -> CMFormatDescription? {
        var out: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(size.width), height: Int32(size.height), extensions: nil,
                                       formatDescriptionOut: &out)
        return out
    }

    /// The host clock now, as a CMTime and in nanoseconds (what CMIO streams are stamped with).
    static func hostNow() -> (time: CMTime, nanoseconds: UInt64) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return (now, UInt64(max(0, CMTimeGetSeconds(now)) * Double(NSEC_PER_SEC)))
    }

    static func sample(_ pixels: CVPixelBuffer, format: CMFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: GlassesCameraSpec.fps),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
                                                     makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                                     sampleTiming: &timing, sampleBufferOut: &out)
        return err == noErr ? out : nil
    }
}
