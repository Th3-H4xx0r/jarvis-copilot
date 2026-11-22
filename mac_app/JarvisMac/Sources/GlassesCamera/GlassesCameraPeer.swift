import Accelerate
import CoreImage
import CoreVideo
import Foundation
import WebRTC

/// The iPhone's glasses video arriving on this Mac: one WebRTC peer, the answerer, the same
/// way a screen share's viewer is answered (ScreenPeer) — but here the phone's offer SENDS
/// video and this side receives it. Each decoded frame is drawn into a 720×1280 BGRA buffer
/// for the camera's sink. WebRTC calls the delegate on its own threads; state hops to main.
final class GlassesCameraPeer: NSObject, RTCPeerConnectionDelegate, RTCVideoRenderer, @unchecked Sendable {
    enum State: Equatable { case connecting, connected, disconnected, failed }

    let viewer: String
    private var pc: RTCPeerConnection?
    private let lock = NSLock()
    private var remoteSet = false
    private var pending: [RTCIceCandidate] = []
    private var track: RTCVideoTrack?
    private var converting = false
    private let converter = GlassesFrameConverter()
    private let frameQueue = DispatchQueue(label: "jarvis.glasses.frames", qos: .userInteractive)

    /// Set on the main actor before `accept`.
    var send: (@MainActor ([String: Any]) -> Void)?
    var onState: (@MainActor (State) -> Void)?
    /// Each frame, ready for the camera. Called off the main thread.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    init(viewer: String, iceServers: [RTCIceServer]) {
        self.viewer = viewer
        super.init()
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        pc = ScreenRTC.factory.peerConnection(with: config, constraints: Self.constraints, delegate: self)
    }

    func accept(offer sdp: String) {
        guard let pc, !sdp.isEmpty else { return }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            guard let self, let pc = self.pc else { return }
            if let error {
                NSLog("Jarvis Glasses camera: bad offer: \(error)")
                self.changed(.failed)
                return
            }
            // The phone's send-only video m-line: its receiver's track is the glasses.
            for transceiver in pc.transceivers where transceiver.mediaType == .video {
                if let track = transceiver.receiver.track as? RTCVideoTrack { self.attach(track) }
            }
            self.lock.lock()
            self.remoteSet = true
            let queued = self.pending
            self.pending = []
            self.lock.unlock()
            for c in queued { pc.add(c) { _ in } }
            pc.answer(for: Self.constraints) { answer, error in
                guard let answer, error == nil else {
                    NSLog("Jarvis Glasses camera: no answer: \(String(describing: error))")
                    self.changed(.failed)
                    return
                }
                pc.setLocalDescription(answer) { error in
                    guard error == nil else { return }
                    let sdp = answer.sdp
                    DispatchQueue.main.async { [weak peer = self] in
                        MainActor.assumeIsolated { peer?.send?(["type": "answer", "sdp": sdp]) }
                    }
                }
            }
        }
    }

    func addRemote(candidate: String, mid: String?, index: Int32) {
        guard !candidate.isEmpty else { return }
        let c = RTCIceCandidate(sdp: candidate, sdpMLineIndex: index, sdpMid: mid)
        lock.lock()
        if !remoteSet {
            pending.append(c)
            lock.unlock()
            return
        }
        lock.unlock()
        pc?.add(c) { _ in }
    }

    func close() {
        lock.lock()
        let track = track
        self.track = nil
        lock.unlock()
        track?.remove(self)
        pc?.close()
        pc = nil
        lock.lock()
        onFrame = nil
        lock.unlock()
    }

    private func attach(_ track: RTCVideoTrack) {
        lock.lock()
        guard self.track == nil else { lock.unlock(); return }
        self.track = track
        lock.unlock()
        track.add(self)
    }

    private func changed(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onState?(state) }
        }
    }

    // MARK: RTCVideoRenderer (WebRTC's decode thread)

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        // One frame in flight: a slow draw drops frames instead of building latency.
        lock.lock()
        if converting { lock.unlock(); return }
        converting = true
        lock.unlock()
        frameQueue.async { [weak self] in
            guard let self else { return }
            let out = self.converter.convert(frame)
            self.lock.lock()
            self.converting = false
            let deliver = self.onFrame
            self.lock.unlock()
            if let out { deliver?(out) }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack { attach(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var c: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
        c["sdpMid"] = candidate.sdpMid ?? NSNull()
        let body: [String: Any] = ["type": "candidate", "candidate": c]
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.send?(body) }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected: changed(.connected)
        case .failed, .closed: changed(.failed)
        case .disconnected: changed(.disconnected)
        default: break
        }
    }
}

/// A decoded WebRTC frame → the camera's 720×1280 BGRA buffer, the picture fitted and centred
/// on black. H.264 frames arrive as CVPixelBuffers (VideoToolbox) and go straight through Core
/// Image; anything else (VP8/VP9) comes as I420 and is converted with vImage first.
final class GlassesFrameConverter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool = GlassesCameraBuffers.pool(GlassesCameraSpec.sinkSize, minimum: 6)
    private let target = GlassesCameraSpec.sinkSize
    private let space = CGColorSpace(name: CGColorSpace.sRGB)

    func convert(_ frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let image = Self.image(frame.buffer)?.oriented(Self.orientation(frame.rotation)),
              let out = GlassesCameraBuffers.buffer(from: pool) else { return nil }
        render(image, into: out)
        return out
    }

    /// `image` fitted into `out` (any size), black around it.
    func render(_ image: CIImage, into out: CVPixelBuffer) {
        let canvas = CGRect(origin: .zero, size: GlassesFrameGeometry.size(of: out))
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let rect = GlassesFrameGeometry.fit(extent.size, in: canvas.size)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let composed = placed.composited(over: CIImage(color: .black).cropped(to: canvas))
        context.render(composed, to: out, bounds: canvas, colorSpace: space)
    }

    static func orientation(_ rotation: RTCVideoRotation) -> CGImagePropertyOrientation {
        switch rotation {
        case ._90: return .right
        case ._180: return .down
        case ._270: return .left
        default: return .up
        }
    }

    private static func image(_ buffer: RTCVideoFrameBuffer) -> CIImage? {
        if let cv = buffer as? RTCCVPixelBuffer {
            let pixels = cv.pixelBuffer
            var image = CIImage(cvPixelBuffer: pixels)
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
            let cx = Int(cv.cropX), cy = Int(cv.cropY), cw = Int(cv.cropWidth), ch = Int(cv.cropHeight)
            if cw > 0, ch > 0, cw != w || ch != h {
                // Core Image's origin is bottom-left; the crop is measured from the top.
                image = image.cropped(to: CGRect(x: cx, y: h - cy - ch, width: cw, height: ch))
            }
            return image
        }
        let i420 = buffer.toI420()
        return bgra(width: Int(i420.width), height: Int(i420.height),
                    y: (i420.dataY, Int(i420.strideY)), u: (i420.dataU, Int(i420.strideU)),
                    v: (i420.dataV, Int(i420.strideV))).map { CIImage(cvPixelBuffer: $0) }
    }

    /// I420 planes (video range, BT.601; chroma at half size) → 32BGRA.
    static func bgra(width w: Int, height h: Int, y yPlane: (UnsafePointer<UInt8>, Int),
                     u uPlane: (UnsafePointer<UInt8>, Int), v vPlane: (UnsafePointer<UInt8>, Int)) -> CVPixelBuffer? {
        guard w > 0, h > 0 else { return nil }
        let chromaW = (w + 1) / 2, chromaH = (h + 1) / 2
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
        guard let pixels = made else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var info = vImage_YpCbCrToARGB()
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
                                                            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888,
                                                            vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        var y = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yPlane.0), height: vImagePixelCount(h),
                              width: vImagePixelCount(w), rowBytes: yPlane.1)
        var cb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: uPlane.0), height: vImagePixelCount(chromaH),
                               width: vImagePixelCount(chromaW), rowBytes: uPlane.1)
        var cr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: vPlane.0), height: vImagePixelCount(chromaH),
                               width: vImagePixelCount(chromaW), rowBytes: vPlane.1)
        var dst = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        let toBGRA: [UInt8] = [3, 2, 1, 0]   // ARGB → BGRA
        let err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &cb, &cr, &dst, &info, toBGRA, 255, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? pixels : nil
    }
}
