import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import WebRTC

/// A display (the main one first; the viewer can switch), captured with ScreenCaptureKit (≤1080p, ≤30 fps, NV12) and
/// fed to one WebRTC video track (shared by every viewer of the share) and, for
/// task shares, an H.264 recording. Everything after `start` runs on `queue`.
final class FramePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxSize = CGSize(width: 1920, height: 1080)
    static let fps: Int32 = 30
    /// A still screen sends no frames; a viewer that joins then would see nothing,
    /// so the last frame is sent again this often while nothing changes.
    static let repeatEvery: TimeInterval = 0.5

    let track: RTCVideoTrack
    /// One injector for the whole share (each viewer's peer holds it): a display
    /// switch moves its bounds, never replaces it.
    let injector = InputInjector(bounds: CGDisplayBounds(CGMainDisplayID()))
    /// The display being shared.
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()
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
    /// Capture ended by itself (not through `stop`): why, for the viewers. Main actor.
    var onStopped: (@MainActor (String) -> Void)?

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

    /// The frame size for a display: its pixels, fitted to 1920×1080.
    static func outputSize(display id: CGDirectDisplayID) -> CGSize {
        // CGDisplayPixels* are points on some setups: the mode's pixels win.
        if let mode = CGDisplayCopyDisplayMode(id) {
            return outputSize(pixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight))
        }
        return outputSize(pixels: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)))
    }

    private func configuration(_ size: CGSize) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.showsCursor = true
        cfg.queueDepth = 6
        return cfg
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display to share"])
        }
        displayID = display.displayID
        injector.setBounds(CGDisplayBounds(display.displayID))
        let size = Self.outputSize(display: display.displayID)
        let cfg = configuration(size)
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

    /// Shares another display, live: the same track (every viewer keeps its
    /// connection), the new display's size, clicks moved over with it. A task's
    /// replay stops at the switch when the size changes (its file is kept).
    func switchDisplay(to id: CGDirectDisplayID) async throws {
        guard let stream else { throw Self.error("The share isn't capturing.") }
        guard id != displayID else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw Self.error("That display isn't connected any more.")
        }
        let size = Self.outputSize(display: id)
        try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: []))
        try await stream.updateConfiguration(configuration(size))
        displayID = id
        injector.setBounds(CGDisplayBounds(id))
        source.adaptOutputFormat(toWidth: Int32(size.width), height: Int32(size.height), fps: Self.fps)
        queue.async { [weak self] in
            self?.lastFrame = nil
            self?.recorder?.sizeChanged(to: size)
        }
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Jarvis", code: 3, userInfo: [NSLocalizedDescriptionKey: text])
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
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.lastFrame = nil
            let text = Self.stopText(error)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onStopped?(text) }
            }
        }
    }

    static func stopText(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userStopped.rawValue {
            return "Sharing was stopped on the Mac."
        }
        return "The Mac stopped capturing the screen (\(ns.localizedDescription))."
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
///
/// The replay goes up in one POST through Cloudflare, which refuses bodies over
/// 100 MB, so the file stays under ~90 MB: 750 kbit/s at 15 fps (plenty for a
/// screen), and recording simply stops — the file kept — at 90 MB or 50 minutes,
/// whichever comes first. The live WebRTC stream is not affected.
final class ScreenRecorder {
    static let bitrate = 750_000
    static let fps: Int32 = 15
    static let maxDuration: Double = 50 * 60
    static let maxBytes: Int64 = 90_000_000

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var first: CMTime?
    private var last: CMTime = .zero
    private var frames = 0
    private var full = false
    private let size: CGSize

    init(shareID: String, size: CGSize) throws {
        self.size = size
        url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-screen-\(shareID).mp4")
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.fps) * 4,
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

    /// The shared display changed: frames of another size can't go in this file.
    func sizeChanged(to newSize: CGSize) {
        if newSize != size { full = true }
    }

    func append(_ pixels: CVPixelBuffer, at time: CMTime) {
        if first == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            first = time
        }
        guard !full, writer.status == .writing, let first, time > last,
              input.isReadyForMoreMediaData else { return }
        // 15 fps is enough for a replay; the first frame always goes in.
        if frames > 0, CMTimeGetSeconds(CMTimeSubtract(time, last)) < 1.0 / Double(Self.fps) * 0.9 { return }
        if CMTimeGetSeconds(CMTimeSubtract(time, first)) >= Self.maxDuration { full = true; return }
        // The writer flushes as it goes: check the file every ~2 s of frames. If its
        // size can't be read, go by the bitrate (with headroom for busy screens).
        if frames > 0, frames % (Int(Self.fps) * 2) == 0 {
            let written = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, first))
            let estimate = Int64(elapsed * Double(Self.bitrate) / 8 * 1.25)
            if (written > 0 ? written : estimate) >= Self.maxBytes {
                full = true
                NSLog("Jarvis screen share: replay reached ~90 MB after \(Int(elapsed)) s, recording stops here")
                return
            }
        }
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
