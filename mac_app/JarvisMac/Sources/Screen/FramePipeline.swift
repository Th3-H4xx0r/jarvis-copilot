import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import WebRTC

/// The main display, captured with ScreenCaptureKit (≤1080p, ≤30 fps, NV12) and
/// fed to one WebRTC video track (shared by every viewer of the share) and, for
/// task shares, an H.264 recording. Everything after `start` runs on `queue`.
final class FramePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxSize = CGSize(width: 1920, height: 1080)
    static let fps: Int32 = 30
    /// A still screen sends no frames; a viewer that joins then would see nothing,
    /// so the last frame is sent again this often while nothing changes.
    static let repeatEvery: TimeInterval = 0.5

    let track: RTCVideoTrack
    private(set) var injector = InputInjector(bounds: CGDisplayBounds(CGMainDisplayID()))
    private let source: RTCVideoSource
    private let rtcCapturer: RTCVideoCapturer
    private let queue = DispatchQueue(label: "jarvis.screen.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var recorder: ScreenRecorder?
    private let record: Bool
    private let shareID: String
    private var lastFrame: CVPixelBuffer?
    private var lastAt: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(record: Bool, shareID: String) {
        self.record = record
        self.shareID = shareID
        source = ScreenRTC.factory.videoSource(forScreenCast: true)
        rtcCapturer = RTCVideoCapturer(delegate: source)
        track = ScreenRTC.factory.videoTrack(with: source, trackId: "jarvis-screen")
        super.init()
    }

    /// Output size: the display's pixels, scaled down to fit 1920×1080, even sides.
    static func outputSize(pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 1280, height: 720) }
        let scale = min(1, min(maxSize.width / pixels.width, maxSize.height / pixels.height))
        func even(_ v: CGFloat) -> CGFloat { CGFloat(max(2, Int((v * scale).rounded()) / 2 * 2)) }
        return CGSize(width: even(pixels.width), height: even(pixels.height))
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display to share"])
        }
        injector = InputInjector(bounds: CGDisplayBounds(display.displayID))
        let pixels = CGSize(width: CGDisplayPixelsWide(display.displayID), height: CGDisplayPixelsHigh(display.displayID))
        var size = Self.outputSize(pixels: pixels)
        // CGDisplayPixels* are points on some setups: never go below the frame's own size.
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            size = Self.outputSize(pixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight))
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.showsCursor = true
        cfg.queueDepth = 6
        source.adaptOutputFormat(toWidth: Int32(size.width), height: Int32(size.height), fps: Self.fps)
        if record {
            recorder = try? ScreenRecorder(shareID: shareID, size: size)
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.repeatEvery, repeating: Self.repeatEvery)
        timer.setEventHandler { [weak self] in self?.repeatLast() }
        timer.resume()
        self.timer = timer
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync { stopped = true; lastFrame = nil }
    }

    /// The recording's file, finished (nil when there was none or it failed).
    func finishRecording() async -> URL? {
        guard let recorder else { return nil }
        self.recorder = nil
        return await withCheckedContinuation { cont in
            queue.async { recorder.finish { cont.resume(returning: $0) } }
        }
    }

    // MARK: frames (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = pixels
        lastAt = CACurrentMediaTime()
        send(pixels)
        recorder?.append(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Jarvis screen share: capture stopped: \(error)")
    }

    private func repeatLast() {
        guard !stopped, let lastFrame, CACurrentMediaTime() - lastAt >= Self.repeatEvery * 0.9 else { return }
        send(lastFrame)
    }

    private func send(_ pixels: CVPixelBuffer) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                                  timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
        source.capturer(rtcCapturer, didCapture: frame)
    }
}

/// H.264 MP4 of a task share (the replay). Runs on the pipeline's queue.
final class ScreenRecorder {
    /// ~1.2 Mbit/s average keeps 50 minutes under the server's 500 MB cap.
    static let bitrate = 1_200_000
    static let maxDuration: Double = 50 * 60

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var first: CMTime?
    private var last: CMTime = .zero
    private var frames = 0

    init(shareID: String, size: CGSize) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-screen-\(shareID).mp4")
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(FramePipeline.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(FramePipeline.fps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else {
            throw NSError(domain: "Jarvis", code: 2, userInfo: [NSLocalizedDescriptionKey: "can't record"])
        }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true  // moov first: the replay starts playing at once
    }

    func append(_ pixels: CVPixelBuffer, at time: CMTime) {
        if first == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            first = time
        }
        guard writer.status == .writing, let first, time > last,
              CMTimeGetSeconds(CMTimeSubtract(time, first)) < Self.maxDuration,
              input.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: time) {
            last = time
            frames += 1
        }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard first != nil, frames > 0, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            done(nil)
            return
        }
        input.markAsFinished()
        // Hold the last frame a moment so a still final screen is visible in the replay.
        writer.endSession(atSourceTime: CMTimeAdd(last, CMTime(seconds: 0.5, preferredTimescale: 600)))
        let url = url
        writer.finishWriting { [writer] in
            done(writer.status == .completed ? url : nil)
        }
    }
}
