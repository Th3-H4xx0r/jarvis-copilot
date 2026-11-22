import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import UIKit
import WebRTC

/// "Send to Mac camera": the glasses' live video as the Mac's "Jarvis Glasses" camera.
///
/// Mac screen sharing run in reverse, on the same Jarvis server signalling and Cloudflare TURN
/// relay (so the phone can be on cellular or another Wi-Fi): the Mac app asks with a "glasses"
/// share while an app there uses its camera; this phone finds the request, joins it as the
/// viewer and OFFERS a send-only video track fed with the glasses' live frames: raw frames from
/// `MetaLivePixels` when the transport has them (only WebRTC's codec compresses them; the Mac
/// decodes back to full frames), else the JPEGs from `MetaGlassesSession.onLiveFrame`, which
/// also keep the connection logic going (live / not live), simulator or real glasses alike.
@MainActor
final class GlassesMacCamera: ObservableObject {
    static let shared = GlassesMacCamera()

    @Published private(set) var phase: GlassesMacCameraMachine.Phase = .off
    /// His switch, remembered: video still only flows while the glasses are live and a Mac asks.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            machine.enabled = enabled
            step()
            if enabled { ensureLoop() }
        }
    }

    static let enabledKey = "meta.macCamera.send"
    static let pollEvery: Duration = .seconds(2)

    private var machine = GlassesMacCameraMachine()
    private let api: JarvisAPI
    private let defaults: UserDefaults
    private var lastFrameAt: Date?
    private var loop: Task<Void, Never>?
    private var peer: GlassesMacCameraPeer?
    private let pump = GlassesFramePump()
    private let raw = GlassesRawFeed()

    init(api: JarvisAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        machine.enabled = enabled
        phase = machine.phase
        MetaLivePixels.setHandler { [raw] pixels in raw.push(pixels) }
    }

    /// The publisher hook: every live frame the glasses send (JPEG ≤720×1280).
    func liveFrame(_ jpeg: Data) {
        lastFrameAt = Date()
        guard enabled else { return }
        // Raw frames flowing: those feed the track; the JPEG copy would only be worse.
        if peer != nil, !raw.recent { pump.push(jpeg) }
        if !machine.glassesLive {
            machine.glassesLive = true
            step()
        }
        ensureLoop()
    }

    /// While on and live: look for the Mac's request every 2 s and keep the connection in line.
    private func ensureLoop() {
        guard loop == nil, enabled else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                let live = self.lastFrameAt.map { Date().timeIntervalSince($0) < GlassesMacCameraMachine.liveTimeout } ?? false
                self.machine.glassesLive = live
                if live && self.enabled {
                    if let reply = try? await self.api.get("/api/screen/shares", query: ["active": "1"], timeout: 10).object() {
                        self.machine.request = GlassesMacCameraMachine.newestRequest(in: reply["shares"] as? [[String: Any]] ?? [])
                    }
                } else {
                    self.machine.request = nil
                }
                self.step()
                // Nothing to watch for: stop until the next frame (or the switch) starts it again.
                if !live || !self.enabled { self.loop = nil; return }
                try? await Task.sleep(for: Self.pollEvery)
            }
        }
    }

    private func step() {
        switch machine.decide(now: Date()) {
        case .connect(let shareID):
            open(shareID)
        case .disconnect:
            close(sayBye: true)
            if case .connect(let next) = machine.decide(now: Date()) { open(next) }
        case .none:
            break
        }
        phase = machine.phase
    }

    private func open(_ shareID: String) {
        let peer = GlassesMacCameraPeer(shareID: shareID, api: api)
        peer.onConnected = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            self.machine.connected()
            self.phase = self.machine.phase
        }
        peer.onFailed = { [weak self, weak peer] why in
            guard let self, let peer, self.peer === peer else { return }
            self.close(sayBye: true)
            self.machine.failed(why, now: Date())
            self.phase = self.machine.phase
        }
        peer.onEnded = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            self.close(sayBye: false)
            self.machine.ended()
            self.phase = self.machine.phase
        }
        self.peer = peer
        pump.start { [weak peer] pixels in peer?.send(pixels) }
        raw.setTarget { [weak peer] pixels in peer?.send(pixels) }
        Task { await peer.start() }
    }

    private func close(sayBye: Bool) {
        guard let peer else { return }
        self.peer = nil
        pump.stop()
        raw.setTarget(nil)
        Task { await peer.stop(sayBye: sayBye) }
    }
}

/// The glasses' video going to one Mac: a WebRTC peer, the offerer — MacScreenSession turned
/// around: the same signalling (`from: viewer` with a viewer id), but the video m-line is
/// send-only and carries the glasses' frames; the Mac answers receive-only.
@MainActor
final class GlassesMacCameraPeer: NSObject {
    let shareID: String
    let viewerID = "glasses-\(UUID().uuidString.prefix(8).lowercased())"
    var onConnected: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onEnded: (() -> Void)?

    private let api: JarvisAPI
    private var pc: RTCPeerConnection?
    nonisolated(unsafe) private let source: RTCVideoSource
    nonisolated(unsafe) private let capturer: RTCVideoCapturer
    private let track: RTCVideoTrack
    private var pollTask: Task<Void, Never>?
    private var afterSeq = 0
    private var remoteSet = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var stopped = false

    /// The glasses stream 720×1280 at 30 fps; cap what goes up so cellular and TURN keep up.
    static let maxBitrate = 4_000_000

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init(shareID: String, api: JarvisAPI) {
        self.shareID = shareID
        self.api = api
        source = Self.factory.videoSource()
        capturer = RTCVideoCapturer(delegate: source)
        track = Self.factory.videoTrack(with: source, trackId: "jarvis-glasses")
        super.init()
        source.adaptOutputFormat(toWidth: Int32(GlassesFramePump.size.width), height: Int32(GlassesFramePump.size.height),
                                 fps: Int32(MetaGen2Profile.liveFPS))
    }

    func start() async {
        do {
            let ice = (try? await api.get("/api/screen/ice", timeout: 20).object()["ice_servers"] as? [[String: Any]]) ?? []
            guard !stopped else { return }
            let config = RTCConfiguration()
            config.iceServers = ice.compactMap { server in
                let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? []
                guard !urls.isEmpty else { return nil }
                return RTCIceServer(urlStrings: urls, username: server["username"] as? String,
                                    credential: server["credential"] as? String)
            }
            config.sdpSemantics = .unifiedPlan
            config.continualGatheringPolicy = .gatherContinually
            config.bundlePolicy = .maxBundle
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                throw APIError.badResponse("WebRTC could not start")
            }
            self.pc = pc
            let video = RTCRtpTransceiverInit()
            video.direction = .sendOnly
            video.streamIds = ["jarvis-glasses"]
            if let sender = pc.addTransceiver(with: track, init: video)?.sender {
                let params = sender.parameters
                // Short of bandwidth, drop frames rather than pixels: a sharp picture on the Mac.
                params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                for encoding in params.encodings {
                    encoding.maxBitrateBps = NSNumber(value: Self.maxBitrate)
                    encoding.maxFramerate = NSNumber(value: MetaGen2Profile.liveFPS)
                }
                sender.parameters = params
            }
            let offer = try await pc.offer(for: constraints)
            try await pc.setLocalDescription(offer)
            try await signal(["type": "offer", "sdp": offer.sdp])
            pollTask = Task { [weak self] in await self?.poll() }
        } catch {
            if !stopped { onFailed?("Couldn't reach your computer: \(apiErrorMessage(error)).") }
        }
    }

    func stop(sayBye: Bool) async {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        pc?.close()
        pc = nil
        if sayBye {
            _ = try? await api.post("/api/screen/shares/\(shareID)/signal",
                                    json: ["from": "viewer", "type": "bye", "viewer": viewerID], timeout: 10)
        }
    }

    /// One 720×1280 BGRA frame into the track (any thread).
    nonisolated func send(_ pixels: CVPixelBuffer) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                                  timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
        source.capturer(capturer, didCapture: frame)
    }

    private func signal(_ body: [String: Any]) async throws {
        var message = body
        message["from"] = "viewer"
        message["viewer"] = viewerID
        _ = try await api.post("/api/screen/shares/\(shareID)/signal", json: message, timeout: 20)
    }

    private func poll() async {
        var failures = 0
        while !Task.isCancelled, !stopped {
            do {
                let reply = try await api.get("/api/screen/shares/\(shareID)/signal",
                                              query: ["for": "viewer", "after": "\(afterSeq)", "viewer": viewerID],
                                              timeout: 35).object()
                failures = 0
                for message in reply["messages"] as? [[String: Any]] ?? [] {
                    afterSeq = max(afterSeq, message["seq"] as? Int ?? afterSeq)
                    await handle(message)
                }
                if reply["status"] as? String == "ended" { if !stopped { onEnded?() }; return }
            } catch {
                if Task.isCancelled || stopped { return }
                if case APIError.http(let code, _) = error, code == 404 || code == 410 { onEnded?(); return }
                failures += 1
                try? await Task.sleep(for: .seconds(min(5, failures)))
            }
        }
    }

    private func handle(_ message: [String: Any]) async {
        guard let pc else { return }
        switch message["type"] as? String {
        case "answer":
            guard let sdp = message["sdp"] as? String, pc.signalingState == .haveLocalOffer else { return }
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                remoteSet = true
                for candidate in pendingCandidates { try? await pc.add(candidate) }
                pendingCandidates = []
            } catch {
                onFailed?("Your Mac's answer didn't fit.")
            }
        case "candidate":
            guard let c = message["candidate"] as? [String: Any], let line = c["candidate"] as? String else { return }
            let candidate = RTCIceCandidate(sdp: line, sdpMLineIndex: Int32(c["sdpMLineIndex"] as? Int ?? 0),
                                            sdpMid: c["sdpMid"] as? String)
            if remoteSet { try? await pc.add(candidate) } else { pendingCandidates.append(candidate) }
        case "bye":
            if !stopped { onEnded?() }
        default:
            break
        }
    }

    fileprivate func sendCandidate(_ body: [String: Any]) {
        guard !stopped else { return }
        Task { try? await signal(body) }
    }

    fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
        guard !stopped else { return }
        switch state {
        case .connected: onConnected?()
        case .failed: onFailed?("Lost the connection to your computer.")
        default: break
        }
    }
}

extension GlassesMacCameraPeer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let body: [String: Any] = ["type": "candidate",
                                   "candidate": ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "",
                                                 "sdpMLineIndex": Int(candidate.sdpMLineIndex)]]
        Task { @MainActor in self.sendCandidate(body) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.connectionChanged(newState) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Raw live frames (MetaLivePixels, the capture queue) → the open peer's track, as they come.
/// `recent` says raw frames are flowing, so the JPEG path stands aside.
final class GlassesRawFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var target: ((CVPixelBuffer) -> Void)?
    private var lastAt: CFTimeInterval = 0

    func setTarget(_ next: ((CVPixelBuffer) -> Void)?) {
        lock.lock(); target = next; lock.unlock()
    }

    func push(_ pixels: CVPixelBuffer) {
        lock.lock()
        lastAt = CACurrentMediaTime()
        let send = target
        lock.unlock()
        send?(pixels)
    }

    var recent: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastAt > 0 && CACurrentMediaTime() - lastAt < 1
    }
}

/// Live frames (JPEG) → 720×1280 BGRA pixel buffers for the WebRTC track, off the main thread.
/// One decode in flight (a slow one drops frames, never builds delay), and the last frame again
/// every half second while the glasses send nothing new, so the Mac's picture never starves.
final class GlassesFramePump: @unchecked Sendable {
    static let size = CGSize(width: MetaGen2Profile.liveWidth, height: MetaGen2Profile.liveHeight)
    static let repeatEvery: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "jarvis.glasses.mac-camera", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    // On `queue`:
    private var deliver: ((CVPixelBuffer) -> Void)?
    private var last: CVPixelBuffer?
    private var lastAt: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private lazy var pool = Self.makePool()

    func start(_ deliver: @escaping (CVPixelBuffer) -> Void) {
        queue.async {
            self.deliver = deliver
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.repeatEvery, repeating: Self.repeatEvery)
            timer.setEventHandler { [weak pump = self] in pump?.repeatLast() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.deliver = nil
            self.timer?.cancel()
            self.timer = nil
            self.last = nil
        }
    }

    func push(_ jpeg: Data) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            guard let deliver = self.deliver, let pixels = Self.render(jpeg: jpeg, pool: self.pool) else { return }
            self.last = pixels
            self.lastAt = CACurrentMediaTime()
            deliver(pixels)
        }
    }

    private func repeatLast() {
        guard let deliver, let last, CACurrentMediaTime() - lastAt >= Self.repeatEvery * 0.9 else { return }
        deliver(last)
    }

    private static func makePool() -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        return pool
    }

    /// A JPEG drawn into a 720×1280 BGRA buffer, fitted and centred on black.
    static func render(jpeg: Data, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool,
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess, let pixels = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(canvas)
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: GlassesMacCameraMachine.fit(CGSize(width: image.width, height: image.height), in: canvas.size))
        return pixels
    }
}
