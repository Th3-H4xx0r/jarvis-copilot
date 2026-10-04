import CoreImage
import CoreMedia
import UIKit
import VideoToolbox

/// Turns the live stream's frames (H.264 / H.265 sample buffers from `DashcamRTSPClient`)
/// into still pictures — CarPlay can't show video, so the car's live view is a picture
/// refreshed every couple of seconds. Every frame is decoded (delta frames need the ones
/// before them); only the newest is kept.
final class DashcamStillDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var latest: CVPixelBuffer?
    private var waitingForKeyframe = true
    private let lock = NSLock()
    private let context = CIContext()

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// False when the frame can't be decoded yet (no keyframe since joining, or the
    /// decoder failed): the caller asks the camera for a keyframe.
    @discardableResult
    func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return false }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if waitingForKeyframe && !isKeyframe { return false }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fmt) }) ?? true {
            guard makeSession(fmt) else { return false }
        }
        guard let session else { return false }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image, let self else { return }
            self.lock.lock()
            self.latest = image
            self.lock.unlock()
        }
        guard status == noErr else {
            reset()
            return false
        }
        waitingForKeyframe = false
        return true
    }

    /// The newest picture, at most `maxSide` points on its longer side.
    func image(maxSide: CGFloat) -> UIImage? {
        lock.lock()
        let pixels = latest
        lock.unlock()
        guard let pixels else { return nil }
        let picture = CIImage(cvPixelBuffer: pixels)
        let longest = max(picture.extent.width, picture.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let scaled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func makeSession(_ fmt: CMFormatDescription) -> Bool {
        reset()
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var made: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &made) == noErr, let made else { return false }
        session = made
        format = fmt
        return true
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        waitingForKeyframe = true
    }
}
