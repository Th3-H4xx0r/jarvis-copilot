import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The pair screen's QR, made on this Mac with CoreImage (CIQRCodeGenerator): black modules on
/// white, scaled by whole pixels so the edges stay crisp. The quiet zone is the window's white card.
enum PairQR {
    /// At least `side` pixels square; nil for nothing to encode.
    static func image(for payload: String, side: CGFloat) -> CGImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // Medium: a phone camera reads it off a screen at an angle.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (side / output.extent.width).rounded(.up))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    private static let context = CIContext()
}
