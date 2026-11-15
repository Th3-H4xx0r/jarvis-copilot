import AVFoundation
import CoreVideo
import Foundation

/// Finds the Mac's screen flash in a grid of camera brightness samples: the cell whose brightness
/// follows the flash code (`HoloBeaconCode.flashFrames`) is where the Mac is in the picture.
enum HoloFlashDetector {
    struct Hit: Equatable {
        let x: Double            // 0 (left edge of the picture) … 1 (right edge)
        let score: Double        // correlation with the code, 0…1
        let contrast: Double     // brightness difference on vs off, in 0–255 luma levels
    }

    /// `frames[t][cell]` = mean luma of each cell (row-major, `cols` wide) at `times[t]` seconds.
    static func detect(frames: [[Float]], times: [Double], cols: Int, code: [Bool],
                       hz: Double = HoloBeaconCode.flashHz) -> Hit? {
        guard let cells = frames.first?.count, cells > 0, cols > 0, frames.count == times.count,
              let t0 = times.first, let tEnd = times.last else { return nil }
        let duration = Double(code.count) / hz
        guard tEnd - t0 >= duration else { return nil }
        var perCell = [(score: Double, contrast: Double, z: Double)](repeating: (0, 0, 0), count: cells)
        var bestScore = 0.0, bestZ = 0.0
        var start = t0
        while start + duration <= tEnd + 1e-9 {
            // Which frames fall inside the code, their slot, and the expected ±1 for each.
            var idx: [Int] = [], slots: [Int] = [], expect: [Double] = []
            for (t, time) in times.enumerated() where time >= start {
                let pos = (time - start) * hz
                let slot = Int(pos.rounded(.down))
                guard slot < code.count else { break }
                // Skip the frames that straddle a slot edge (exposure blends the two).
                let into = pos - Double(slot)
                guard into > 0.15, into < 0.85 else { continue }
                idx.append(t)
                slots.append(slot)
                expect.append(code[slot] ? 1 : -1)
            }
            let ons = expect.filter { $0 > 0 }.count, offs = expect.count - ons
            let usedSlots = Set(slots).count
            if usedSlots >= code.count - 1, ons > 0, offs > 0 {
                let eMean = expect.reduce(0, +) / Double(expect.count)
                let eDev = expect.map { $0 - eMean }
                let eNorm = eDev.reduce(0) { $0 + $1 * $1 }.squareRoot()
                for c in 0..<cells {
                    let xs = idx.map { Double(frames[$0][c]) }
                    let mean = xs.reduce(0, +) / Double(xs.count)
                    var num = 0.0, den = 0.0, on = 0.0, off = 0.0
                    var slotSum = [Double](repeating: 0, count: code.count), slotN = slotSum
                    for (i, v) in xs.enumerated() {
                        num += (v - mean) * eDev[i]
                        den += (v - mean) * (v - mean)
                        if expect[i] > 0 { on += v } else { off += v }
                        slotSum[slots[i]] += v
                        slotN[slots[i]] += 1
                    }
                    guard den > 0, eNorm > 0 else { continue }
                    let score = num / (den.squareRoot() * eNorm)
                    let contrast = on / Double(ons) - off / Double(offs)
                    // The cell's own noise: how much frames wobble inside one slot.
                    var resid = 0.0
                    for (i, v) in xs.enumerated() { let m = slotSum[slots[i]] / slotN[slots[i]]; resid += (v - m) * (v - m) }
                    let dof = max(1, xs.count - usedSlots)
                    let sigma = max((resid / Double(dof)).squareRoot(), 0.05)
                    let z = contrast / (sigma * (1 / Double(ons) + 1 / Double(offs)).squareRoot())
                    if score > perCell[c].score { perCell[c] = (score, contrast, z) }
                    if score > bestScore { bestScore = score; bestZ = z }
                }
            }
            start += 1.0 / 30
        }
        // Far above the cell's own noise (≥ 6σ) and clearly correlated: random flicker over
        // ~200 cells × ~50 offsets never gets there; a real flash easily does.
        guard bestScore >= 0.7, bestZ >= 6 else { return nil }
        var sumW = 0.0, sumX = 0.0, contrast = 0.0
        for (c, v) in perCell.enumerated() where v.score >= bestScore * 0.8 && v.z >= 6 && v.contrast >= 1 {
            sumW += v.score
            sumX += v.score * (Double(c % cols) + 0.5) / Double(cols)
            contrast = max(contrast, v.contrast)
        }
        guard sumW > 0 else { return nil }
        return Hit(x: sumX / sumW, score: bestScore, contrast: contrast)
    }

    /// The horizontal angle of `x` in a picture `fovDeg` wide: negative = left of centre.
    static func offset(x: Double, fovDeg: Double) -> Double {
        let half = fovDeg * .pi / 360
        return atan((x - 0.5) * 2 * tan(half)) * 180 / .pi
    }

    /// A camera's horizontal field of view when the phone is upright: the sensor's long side
    /// (what AVFoundation reports) is vertical then.
    static func portraitFOV(landscapeFOV: Double, width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return landscapeFOV }
        let short = min(width, height), long = max(width, height)
        return 2 * atan(tan(landscapeFOV * .pi / 360) * short / long) * 180 / .pi
    }
}

/// "Look at it": the back camera watches for the Mac's flash while he points the phone at it.
@MainActor
final class HoloLook: NSObject, ObservableObject {
    struct Reading: Equatable {
        let offsetDeg: Double      // where the Mac is relative to where the phone points
        let confidence: Double
    }

    static let shared = HoloLook()
    let session = AVCaptureSession()
    @Published private(set) var running = false
    private let collector = GridCollector()
    private let queue = DispatchQueue(label: "holo.look")
    private var fov = 60.0

    /// Starts the camera, calls `ask` (the Mac flashes), watches `seconds`, finds the flash.
    private var cancelled = false

    func look(nonce: String, seconds: Double = 2.6, ask: @escaping () async -> Void) async -> Reading? {
        cancelled = false
        guard await AVCaptureDevice.requestAccess(for: .video), !cancelled, configure() else { return nil }
        running = true
        let s = session
        queue.async { s.startRunning() }
        try? await Task.sleep(for: .milliseconds(500))         // exposure settles before the flash
        guard !cancelled else { stop(); return nil }           // the popup closed meanwhile
        lockExposure()
        collector.reset()
        await ask()
        try? await Task.sleep(for: .seconds(seconds))
        let wasCancelled = cancelled
        stop()
        if wasCancelled { return nil }
        let (frames, times) = collector.take()
        guard let hit = HoloFlashDetector.detect(frames: frames, times: times, cols: GridCollector.cols,
                                                 code: HoloBeaconCode.flashFrames(nonce)) else { return nil }
        return Reading(offsetDeg: HoloFlashDetector.offset(x: hit.x, fovDeg: fov),
                       confidence: min(0.95, 0.5 + hit.score / 2))
    }

    func stop() {
        cancelled = true
        running = false
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
        if let camera = (session.inputs.first as? AVCaptureDeviceInput)?.device,
           camera.isExposureModeSupported(.continuousAutoExposure), (try? camera.lockForConfiguration()) != nil {
            camera.exposureMode = .continuousAutoExposure
            camera.unlockForConfiguration()
        }
    }

    private func configure() -> Bool {
        if !session.inputs.isEmpty { return true }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(collector, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90                      // upright buffers: x is left→right on screen
        }
        session.commitConfiguration()
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        fov = HoloFlashDetector.portraitFOV(landscapeFOV: Double(camera.activeFormat.videoFieldOfView),
                                            width: Double(dims.width), height: Double(dims.height))
        if (try? camera.lockForConfiguration()) != nil {
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        }
        return true
    }

    /// Auto-exposure would chase the flash and hide it.
    private func lockExposure() {
        guard let camera = (session.inputs.first as? AVCaptureDeviceInput)?.device,
              camera.isExposureModeSupported(.locked), (try? camera.lockForConfiguration()) != nil else { return }
        camera.exposureMode = .locked
        camera.unlockForConfiguration()
    }

    /// Mean brightness per grid cell per frame, from the camera queue.
    final class GridCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        static let cols = 12, rows = 16
        private let lock = NSLock()
        private var frames: [[Float]] = []
        private var times: [Double] = []
        private var first: Double?

        func reset() {
            lock.lock(); frames = []; times = []; first = nil; lock.unlock()
        }

        func take() -> ([[Float]], [Double]) {
            lock.lock(); defer { lock.unlock() }
            return (frames, times)
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            CVPixelBufferLockBaseAddress(px, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return }
            let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var grid = [Float](repeating: 0, count: Self.cols * Self.rows)
            let cw = max(1, w / Self.cols), ch = max(1, h / Self.rows)
            for r in 0..<Self.rows {
                for c in 0..<Self.cols {
                    var sum = 0, n = 0
                    var y = r * ch
                    while y < min(h, (r + 1) * ch) {
                        var x = c * cw
                        while x < min(w, (c + 1) * cw) { sum += Int(bytes[y * stride + x]); n += 1; x += 4 }
                        y += 4
                    }
                    grid[r * Self.cols + c] = n > 0 ? Float(sum) / Float(n) : 0
                }
            }
            lock.lock()
            if first == nil { first = t }
            frames.append(grid)
            times.append(t - (first ?? t))
            lock.unlock()
        }
    }
}
