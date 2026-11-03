import AppKit
import CoreMedia
import Foundation
import WebRTC

/// One share on this Mac: the capture, a WebRTC peer per viewer, the signalling
/// long poll and (task shares) the recording that is uploaded when it ends.
///
/// The viewer offers (recvonly video + data channel "input"); this side answers
/// with the display track. Signal messages may carry a `viewer` id — the answer
/// and candidates echo it, so a phone and a browser can watch at once.
@MainActor
final class ScreenShareSession {
    let id: String
    let reason: String
    private let origin: String

    var onViewers: ((Int) -> Void)?
    var onFinished: ((String) -> Void)?
    var onPermissionProblem: ((String) -> Void)?

    private var pipeline: FramePipeline?
    private var peers: [String: ScreenPeer] = [:]
    private var iceServers: [RTCIceServer] = []
    private var seq = 0
    private var signalTask: Task<Void, Never>?
    private var ended = false

    var viewerCount: Int { peers.values.filter(\.connected).count }

    init(id: String, reason: String, origin: String) {
        self.id = id
        self.reason = reason
        self.origin = origin
    }

    func start() {
        Task { [weak self] in await self?.run() }
    }

    /// Stop from this Mac (the banner's Stop, or a failure): tell the server.
    func stop(reason error: String?) {
        finish(local: true, error: error)
    }

    /// The server says the share is over.
    func endedRemotely() {
        finish(local: false, error: nil)
    }

    private func run() async {
        iceServers = await Self.fetchIce(origin)
        let pipeline = FramePipeline(record: reason == "task", shareID: id)
        do {
            try await pipeline.start()
        } catch {
            let text: String
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()  // the system prompt, once
                text = "Jarvis can't see your screen — allow Jarvis under Screen & System Audio Recording."
            } else {
                text = "Jarvis couldn't capture the screen: \(error.localizedDescription)"
            }
            onPermissionProblem?(text)
            finish(local: true, error: text)
            return
        }
        guard !ended else { await pipeline.stop(); return }
        self.pipeline = pipeline
        signalTask = Task { [weak self] in await self?.signalLoop() }
    }

    // MARK: signalling

    private func signalLoop() async {
        var failures = 0
        while !ended && !Task.isCancelled {
            let path = "/api/screen/shares/\(id)/signal?for=mac&after=\(seq)&wait=25"
            guard let obj = await ScreenAPI.getJSON(origin, path, timeout: 40) else {
                failures += 1
                try? await Task.sleep(for: .seconds(min(5, failures)))
                continue
            }
            failures = 0
            let status = J.i(obj["_status"])
            if status == 404 || status == 410 { endedRemotely(); return }
            for msg in J.arr(obj["messages"]) {
                seq = max(seq, J.i(msg["seq"]))
                handle(msg)
            }
            if J.s(obj["status"]) == "ended" { endedRemotely(); return }
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard J.s(msg["from"]) == "viewer", let pipeline else { return }
        let viewer = J.s(msg["viewer"])
        switch J.s(msg["type"]) {
        case "offer":
            peers.removeValue(forKey: viewer)?.close()
            let peer = ScreenPeer(viewer: viewer, iceServers: iceServers, track: pipeline.track,
                                  injector: pipeline.injector)
            peer.send = { [weak self] body in self?.post(body, viewer: viewer) }
            peer.onState = { [weak self, weak peer] in
                guard let self, let peer else { return }
                if peer.gone, self.peers[viewer] === peer { self.peers[viewer] = nil }
                self.onViewers?(self.viewerCount)
            }
            peers[viewer] = peer
            peer.accept(offer: J.s(msg["sdp"]))
        case "candidate":
            let c = J.obj(msg["candidate"])
            peers[viewer]?.addRemote(candidate: J.s(c["candidate"]), mid: c["sdpMid"] as? String,
                                     index: Int32(J.i(c["sdpMLineIndex"])))
        case "bye":
            peers.removeValue(forKey: viewer)?.close()
            onViewers?(viewerCount)
        default:
            break
        }
    }

    private func post(_ body: [String: Any], viewer: String) {
        guard !ended else { return }
        var msg = body
        msg["from"] = "mac"
        if !viewer.isEmpty { msg["viewer"] = viewer }
        let origin = origin, id = id
        Task { await ScreenAPI.postJSON(origin, "/api/screen/shares/\(id)/signal", msg) }
    }

    // MARK: ending

    private func finish(local: Bool, error: String?) {
        guard !ended else { return }
        ended = true
        signalTask?.cancel()
        for p in peers.values { p.close() }
        peers = [:]
        onViewers?(0)
        let origin = origin, id = id, pipeline = pipeline
        self.pipeline = nil
        onFinished?(id)
        Task.detached {
            if local {
                var body: [String: Any] = [:]
                if let error { body["error"] = error }
                await ScreenAPI.postJSON(origin, "/api/screen/shares/\(id)/stop", body)
            }
            guard let pipeline else { return }
            await pipeline.stop()
            if let file = await pipeline.finishRecording() {
                await Self.upload(file, origin: origin, id: id)
            }
        }
    }

    nonisolated private static func upload(_ file: URL, origin: String, id: String) async {
        defer { try? FileManager.default.removeItem(at: file) }
        guard var req = ScreenAPI.request(origin, "/api/screen/shares/\(id)/replay", method: "POST", timeout: 900)
        else { return }
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        for attempt in 0..<2 {
            if let (_, resp) = try? await URLSession.shared.upload(for: req, fromFile: file),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
        }
        NSLog("Jarvis screen share \(id): replay upload failed")
    }

    nonisolated private static func fetchIce(_ origin: String) async -> [RTCIceServer] {
        let obj = await ScreenAPI.getJSON(origin, "/api/screen/ice", timeout: 10) ?? [:]
        var out: [RTCIceServer] = []
        for s in J.arr(obj["ice_servers"]) {
            let urls = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
            guard !urls.isEmpty else { continue }
            if let user = s["username"] as? String, let cred = s["credential"] as? String {
                out.append(RTCIceServer(urlStrings: urls, username: user, credential: cred))
            } else {
                out.append(RTCIceServer(urlStrings: urls))
            }
        }
        if out.isEmpty { out = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])] }
        return out
    }
}

/// The one WebRTC factory of the app (H.264 / VP8 / VP9 through the defaults).
enum ScreenRTC {
    nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
}

/// One viewer's peer connection (answerer). WebRTC calls its delegate methods on
/// its own signalling thread; state changes hop to the main actor.
final class ScreenPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    let viewer: String
    private var pc: RTCPeerConnection?
    private let track: RTCVideoTrack
    private let injector: InputInjector
    private let lock = NSLock()
    private var remoteSet = false
    private var pending: [RTCIceCandidate] = []
    private var channel: RTCDataChannel?

    /// Set on the main actor before `accept`.
    var send: (@MainActor ([String: Any]) -> Void)?
    var onState: (@MainActor () -> Void)?
    private(set) var connected = false
    private(set) var gone = false

    private static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    init(viewer: String, iceServers: [RTCIceServer], track: RTCVideoTrack, injector: InputInjector) {
        self.viewer = viewer
        self.track = track
        self.injector = injector
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
            if let error { NSLog("Jarvis screen share: bad offer: \(error)"); return }
            // The viewer's recvonly video m-line takes our display track.
            _ = pc.add(self.track, streamIds: ["jarvis-screen"])
            self.lock.lock()
            self.remoteSet = true
            let queued = self.pending
            self.pending = []
            self.lock.unlock()
            for c in queued { pc.add(c) { _ in } }
            pc.answer(for: Self.constraints) { answer, error in
                guard let answer, error == nil else { NSLog("Jarvis screen share: no answer: \(String(describing: error))"); return }
                pc.setLocalDescription(answer) { error in
                    guard error == nil else { return }
                    let sdp = answer.sdp
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.send?(["type": "answer", "sdp": sdp]) }
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
        gone = true
        connected = false
        channel?.close()
        pc?.close()
        pc = nil
    }

    private func changed(connected: Bool, gone: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = connected
                if gone { self.gone = true }
                self.onState?()
            }
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
        case .connected: changed(connected: true, gone: false)
        case .failed, .closed: changed(connected: false, gone: true)
        case .disconnected: changed(connected: false, gone: false)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == "input" else { return }
        dataChannel.delegate = self
        channel = dataChannel
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let obj = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
        if let problem = injector.handle(obj) {
            // Tell the viewer once why its clicks do nothing (it may show it or ignore it).
            let reply = (try? JSONSerialization.data(withJSONObject: ["t": "error", "error": problem])) ?? Data()
            dataChannel.sendData(RTCDataBuffer(data: reply, isBinary: false))
        }
    }
}
