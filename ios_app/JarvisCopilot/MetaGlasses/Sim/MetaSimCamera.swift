import AVFoundation
import UIKit

/// What stands in for the glasses' camera in the simulator.
@MainActor
protocol MetaCameraSource: AnyObject {
    /// "iPhone camera" or "Test scene" — shown on the Sim screen and in the feed.
    var sourceName: String { get }
    /// A full-size still, JPEG, portrait 3024×4032 (the glasses' 12 MP).
    func capturePhoto() async throws -> Data
    /// Start a clip at `mode`, at most `maxSeconds` long.
    func startRecording(mode: MetaVideoMode, maxSeconds: Int) async throws
    /// Stop the clip. Returns the movie file (nil when there is no real video, e.g. a test scene).
    func stopRecording() async -> URL?
    /// Live frames (JPEG, ≤720×1280) until `stopLive()`.
    func startLive(onFrame: @escaping @MainActor (Data) -> Void) async throws
    func stopLive()
}

/// The fallback camera: drawn test scenes, so capture works with no camera (background, no
/// permission, the simulator, tests). Clips carry no movie file.
@MainActor
final class MetaTestSceneCamera: MetaCameraSource {
    let sourceName = "Test scene"
    private let photoSize: CGSize
    private var liveTask: Task<Void, Never>?
    private var shot = 0

    init(photoSize: CGSize = CGSize(width: MetaGen2Profile.photoWidth, height: MetaGen2Profile.photoHeight)) {
        self.photoSize = photoSize
    }

    func capturePhoto() async throws -> Data {
        shot += 1
        return Self.scene(size: photoSize, frame: shot, caption: "Test scene \(shot)")
    }

    func startRecording(mode: MetaVideoMode, maxSeconds: Int) async throws {}
    func stopRecording() async -> URL? { nil }

    func startLive(onFrame: @escaping @MainActor (Data) -> Void) async throws {
        stopLive()
        liveTask = Task { @MainActor in
            var frame = 0
            while !Task.isCancelled {
                frame += 1
                onFrame(Self.scene(size: CGSize(width: 360, height: 640), frame: frame, caption: "Live test scene"))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stopLive() { liveTask?.cancel(); liveTask = nil }

    /// A simple, recognisable scene: a desk with a mug and a book under a window, a clock in the
    /// corner that moves with `frame`, and a caption — enough for vision to describe something.
    static func scene(size: CGSize, frame: Int, caption: String) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height
            UIColor(red: 0.80, green: 0.88, blue: 0.95, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.55))
            UIColor(red: 0.55, green: 0.38, blue: 0.24, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45))
            UIColor.white.setFill(); c.fill(CGRect(x: w * 0.15, y: h * 0.08, width: w * 0.7, height: h * 0.35))
            UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1).setFill(); c.fill(CGRect(x: w * 0.18, y: h * 0.10, width: w * 0.64, height: h * 0.31))
            UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1).setFill()
            c.fill(CGRect(x: w * 0.20, y: h * 0.62, width: w * 0.18, height: h * 0.16))          // mug
            c.setStrokeColor(UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1).cgColor); c.setLineWidth(w * 0.02)
            c.strokeEllipse(in: CGRect(x: w * 0.36, y: h * 0.65, width: w * 0.08, height: h * 0.08))
            UIColor(red: 0.15, green: 0.30, blue: 0.60, alpha: 1).setFill()
            c.fill(CGRect(x: w * 0.52, y: h * 0.70, width: w * 0.32, height: h * 0.08))           // book
            let angle = Double(frame % 60) / 60 * 2 * .pi
            let centre = CGPoint(x: w * 0.85, y: h * 0.50), r = w * 0.06
            UIColor.white.setFill(); c.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(max(2, w * 0.006))
            c.move(to: centre); c.addLine(to: CGPoint(x: centre.x + r * 0.9 * sin(angle), y: centre.y - r * 0.9 * cos(angle))); c.strokePath()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: w * 0.045, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            (caption as NSString).draw(at: CGPoint(x: w * 0.05, y: h * 0.90), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

/// The iPhone's back camera as the glasses' camera — the ultra-wide when the phone has one (the
/// glasses' lens is ultra-wide), else the main camera. Photos come back portrait 3024×4032; clips
/// record to a movie file capped at the clip length; live frames are 720×1280-class JPEGs.
@MainActor
final class MetaPhoneCamera: NSObject, MetaCameraSource {
    let sourceName = "iPhone camera"
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "meta.sim.camera")
    private var configured = false
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var movieContinuation: CheckedContinuation<URL?, Never>?
    private var frameSink: FrameSink?

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        if authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// A camera is usable now: permission given, the app in front, and a back camera exists.
    static var available: Bool {
        authorized && UIApplication.shared.applicationState == .active && device() != nil
    }

    private static func device() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configure() throws {
        guard !configured else { return }
        guard let device = Self.device() else { throw MetaGlassesError.transportUnavailable("no back camera") }
        session.beginConfiguration()
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // The largest still the sensor gives up to 12 MP (the glasses' resolution).
        if let best = device.activeFormat.supportedMaxPhotoDimensions
            .filter({ Int($0.width) * Int($0.height) <= 12_200_000 })
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = best
        }
        for output in [photoOutput as AVCaptureOutput, movieOutput, videoOutput] {
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90       // portrait, like the glasses
            }
        }
        session.commitConfiguration()
        configured = true
    }

    private func ensureRunning() async throws {
        guard Self.available else { throw MetaGlassesError.transportUnavailable("camera not available") }
        try configure()
        if !session.isRunning {
            let session = self.session
            await withCheckedContinuation { cont in queue.async { session.startRunning(); cont.resume() } }
        }
    }

    private func stopIfIdle() {
        guard !movieOutput.isRecording, frameSink == nil, photoContinuation == nil else { return }
        let session = self.session
        queue.async { session.stopRunning() }
    }

    func capturePhoto() async throws -> Data {
        try await ensureRunning()
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        let raw: Data = try await withCheckedThrowingContinuation { cont in
            photoContinuation = cont
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        stopIfIdle()
        return Self.fitToGlasses(raw) ?? raw
    }

    /// Crop/scale to the glasses' portrait 3:4 frame at 3024×4032.
    static func fitToGlasses(_ jpeg: Data) -> Data? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let target = CGSize(width: MetaGen2Profile.photoWidth, height: MetaGen2Profile.photoHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2)
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawn))
        }.jpegData(compressionQuality: 0.88)
    }

    func startRecording(mode: MetaVideoMode, maxSeconds: Int) async throws {
        try await ensureRunning()
        movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxSeconds), preferredTimescale: 600)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-sim-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() async -> URL? {
        guard movieOutput.isRecording else { return nil }
        let url: URL? = await withCheckedContinuation { cont in
            movieContinuation = cont
            movieOutput.stopRecording()
        }
        stopIfIdle()
        return url
    }

    func startLive(onFrame: @escaping @MainActor (Data) -> Void) async throws {
        try await ensureRunning()
        let sink = FrameSink(onFrame: onFrame)
        frameSink = sink
        videoOutput.setSampleBufferDelegate(sink, queue: queue)
    }

    func stopLive() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        frameSink = nil
        stopIfIdle()
    }

    /// Turns camera frames into ~10 fps JPEGs at most 720 wide.
    private final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let onFrame: @MainActor (Data) -> Void
        private let context = CIContext()
        private var last = Date.distantPast
        init(onFrame: @escaping @MainActor (Data) -> Void) { self.onFrame = onFrame }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            let now = Date()
            guard now.timeIntervalSince(last) > 0.1, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            last = now
            var image = CIImage(cvPixelBuffer: pixels)
            let scale = min(1, CGFloat(MetaGen2Profile.liveWidth) / image.extent.width)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(image, from: image.extent),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { return }
            Task { @MainActor in self.onFrame(jpeg) }
        }
    }
}

extension MetaPhoneCamera: AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            let cont = self.photoContinuation
            self.photoContinuation = nil
            if let data { cont?.resume(returning: data) }
            else { cont?.resume(throwing: error ?? MetaGlassesError.transportUnavailable("no photo")) }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let cont = self.movieContinuation
            self.movieContinuation = nil
            // Reaching maxRecordedDuration reports an "error" but the file is complete.
            cont?.resume(returning: FileManager.default.fileExists(atPath: outputFileURL.path) ? outputFileURL : nil)
        }
    }
}

/// The sim's camera: the iPhone camera whenever it's usable, test scenes otherwise.
@MainActor
final class MetaSimCamera: MetaCameraSource {
    private let phone = MetaPhoneCamera()
    private let scenes = MetaTestSceneCamera()
    private var recordingWith: MetaCameraSource?
    private var liveWith: MetaCameraSource?
    var preferPhone = true

    private var current: MetaCameraSource { preferPhone && MetaPhoneCamera.available ? phone : scenes }
    var sourceName: String { current.sourceName }

    func capturePhoto() async throws -> Data {
        do { return try await current.capturePhoto() }
        catch { return try await scenes.capturePhoto() }
    }

    func startRecording(mode: MetaVideoMode, maxSeconds: Int) async throws {
        let source = current
        do { try await source.startRecording(mode: mode, maxSeconds: maxSeconds); recordingWith = source }
        catch { try await scenes.startRecording(mode: mode, maxSeconds: maxSeconds); recordingWith = scenes }
    }

    func stopRecording() async -> URL? {
        let source = recordingWith
        recordingWith = nil
        return await source?.stopRecording()
    }

    func startLive(onFrame: @escaping @MainActor (Data) -> Void) async throws {
        let source = current
        do { try await source.startLive(onFrame: onFrame); liveWith = source }
        catch { try await scenes.startLive(onFrame: onFrame); liveWith = scenes }
    }

    func stopLive() { liveWith?.stopLive(); liveWith = nil }
}
