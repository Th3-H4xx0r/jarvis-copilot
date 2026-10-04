import CoreMedia
import UIKit
import VideoToolbox
import XCTest
@testable import JarvisCopilot

/// The car's dashcam live view: frames from the live stream decoded into still pictures.
final class DashcamStillDecoderTests: XCTestCase {

    func testNoPictureBeforeAnyFrame() {
        XCTAssertNil(DashcamStillDecoder().image(maxSide: 64))
    }

    func testDecodesTheStreamIntoAPicture() throws {
        let samples = try Self.encodedSamples(count: 3)
        let decoder = DashcamStillDecoder()
        for sample in samples { XCTAssertTrue(decoder.decode(sample)) }
        let image = try XCTUnwrap(decoder.image(maxSide: 64))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 64)
        XCTAssertGreaterThan(min(image.size.width, image.size.height), 0)
    }

    /// Joining mid-stream: a delta frame can't be decoded until a keyframe comes.
    func testADeltaFrameFirstAsksForAKeyframe() throws {
        let samples = try Self.encodedSamples(count: 3)
        let decoder = DashcamStillDecoder()
        XCTAssertFalse(decoder.decode(samples[1]))
        XCTAssertNil(decoder.image(maxSide: 64))
        XCTAssertTrue(decoder.decode(samples[0]))
    }

    /// H.264 samples straight from VideoToolbox (keyframe first), as the RTSP client hands them over.
    static func encodedSamples(count: Int, width: Int32 = 160, height: Int32 = 120) throws -> [CMSampleBuffer] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw XCTSkip("no H.264 encoder here") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        let lock = NSLock()
        var out: [CMSampleBuffer] = []
        for i in 0..<count {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, nil, &pixels)
            guard let pixels else { throw XCTSkip("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(40 + i * 60), CVPixelBufferGetDataSize(pixels))   // a different grey per frame
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let props = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sb in
                guard status == noErr, let sb else { return }
                lock.lock(); out.append(sb); lock.unlock()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock(); defer { lock.unlock() }
        guard out.count == count else { throw XCTSkip("encoder produced \(out.count) of \(count) frames") }
        return out
    }
}
