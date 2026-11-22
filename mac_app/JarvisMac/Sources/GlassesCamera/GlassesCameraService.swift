import AppKit
import Foundation
import Observation
import WebRTC

/// The Jarvis Glasses camera's live side on this Mac. Once a second: is the camera installed,
/// is an app using it? While one is, it ASKS for the glasses' video — a share with reason
/// "glasses" on the Jarvis server, the same signalling as Mac screen sharing
/// (ScreenShareService), run in reverse: the iPhone joins as the viewer and offers send-only
/// video, this Mac answers, and the frames go into the camera's sink (GlassesCameraSink).
/// Video goes peer to peer or through the server's Cloudflare TURN relay, so the phone can be
/// on cellular or another network. When no app has used the camera for a while it stops
/// asking (the phone then stops sending) and lets the sink go.
@MainActor
@Observable
final class GlassesCameraService {
    static let shared = GlassesCameraService()

    private(set) var phase: GlassesCameraPhase = .notInstalled
    /// Apps using the camera right now (nil = the extension doesn't say).
    private(set) var appsUsing: Int?

    @ObservationIgnored private var demand = GlassesCameraDemand()
    @ObservationIgnored private let sink = GlassesCameraSink()
    @ObservationIgnored private let frames = GlassesFrameClock()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var device: GlassesCameraSink.Device?
    @ObservationIgnored private var lookedAt = Date.distantPast
    @ObservationIgnored private var shareID: String?
    @ObservationIgnored private var origin: String?
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var iceServers: [RTCIceServer] = []
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var peer: GlassesCameraPeer?
    @ObservationIgnored private var peerState: GlassesCameraPeer.State?
    @ObservationIgnored private var earlyCandidates: [String: [[String: Any]]] = [:]
    @ObservationIgnored private var outbox: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Look for the camera again now (after Settings installed it).
    func refresh() {
        lookedAt = .distantPast
        Task { await tick() }
    }

    private func tick() async {
        let now = Date()
        // The camera comes and goes with the extension: look again every 10 s, or at once
        // when the device we had stops answering.
        if device == nil || now.timeIntervalSince(lookedAt) > 10 {
            device = GlassesCameraSink.findDevice()
            lookedAt = now
        }
        var clients = device.flatMap { GlassesCameraSink.clients(on: $0.source) }
        if device != nil, clients == nil {
            device = GlassesCameraSink.findDevice()
            clients = device.flatMap { GlassesCameraSink.clients(on: $0.source) }
        }
        appsUsing = clients
        let installed = device != nil
        let wanted = demand.wanted(installed: installed, clients: clients, now: now)
        let origin = AppModel.shared.apiOrigin
        if wanted, let origin {
            if !sink.isStarted { sink.start() }
            if shareID == nil, !asking { await ask(origin) }
        } else if !wanted {
            if shareID != nil { endShare(tellServer: true) }
            if sink.isStarted { sink.stop() }
        }
        phase = .of(installed: installed, wanted: wanted, online: origin != nil, asked: shareID != nil,
                    peer: peer == nil ? nil : peerState, frameFresh: frames.fresh(within: GlassesCameraSpec.staleAfter))
    }

    // MARK: The request ("glasses" share)

    private func ask(_ origin: String) async {
        asking = true
        defer { asking = false }
        guard let obj = await ScreenAPI.postJSON(origin, "/api/screen/shares", ["reason": "glasses"], timeout: 15),
              J.i(obj["_status"]) == 200 else { return }
        let id = J.s(obj["id"])
        guard !id.isEmpty else { return }
        iceServers = ScreenShareSession.iceServers(from: obj)
        self.origin = origin
        shareID = id
        seq = 0
        earlyCandidates = [:]
        signalTask = Task { [weak self] in await self?.signalLoop(id) }
    }

    private func signalLoop(_ id: String) async {
        var failures = 0
        while shareID == id, !Task.isCancelled, let origin {
            let path = "/api/screen/shares/\(id)/signal?for=mac&after=\(seq)&wait=25"
            guard let obj = await ScreenAPI.getJSON(origin, path, timeout: 40) else {
                failures += 1
                try? await Task.sleep(for: .seconds(min(5, failures)))
                continue
            }
            guard shareID == id else { return }
            failures = 0
            let status = J.i(obj["_status"])
            if status == 404 || status == 410 { shareEnded(id); return }
            for msg in J.arr(obj["messages"]) {
                seq = max(seq, J.i(msg["seq"]))
                handle(msg)
            }
            if J.s(obj["status"]) == "ended" { shareEnded(id); return }
        }
    }

    /// The server ended it (a restart, too old): the next tick asks again if still wanted.
    private func shareEnded(_ id: String) {
        guard shareID == id else { return }
        closePeer()
        shareID = nil
        signalTask = nil
    }

    private func endShare(tellServer: Bool) {
        guard let id = shareID else { return }
        signalTask?.cancel()
        signalTask = nil
        closePeer()
        shareID = nil
        if tellServer, let origin {
            Task.detached { await ScreenAPI.postJSON(origin, "/api/screen/shares/\(id)/stop", [:]) }
        }
    }

    // MARK: The phone's peer

    private func handle(_ msg: [String: Any]) {
        guard J.s(msg["from"]) == "viewer" else { return }
        let viewer = J.s(msg["viewer"])
        switch J.s(msg["type"]) {
        case "offer":
            // One phone at a time: the newest offer wins (a reconnect replaces the old peer).
            closePeer()
            let peer = GlassesCameraPeer(viewer: viewer, iceServers: iceServers)
            peer.send = { [weak self] body in self?.post(body, viewer: viewer) }
            peer.onState = { [weak self, weak peer] state in
                guard let self, let peer, self.peer === peer else { return }
                self.peerState = state
                if state == .failed { self.closePeer() }
            }
            let sink = sink, frames = frames
            peer.onFrame = { pixels in
                frames.mark()
                sink.write(pixels)
            }
            self.peer = peer
            peerState = .connecting
            peer.accept(offer: J.s(msg["sdp"]))
            for c in earlyCandidates.removeValue(forKey: viewer) ?? [] { add(c, to: peer) }
        case "candidate":
            let c = J.obj(msg["candidate"])
            if let peer, peer.viewer == viewer {
                add(c, to: peer)
            } else {
                var queued = earlyCandidates[viewer] ?? []
                if queued.count < 64 { queued.append(c) }
                earlyCandidates[viewer] = queued
                if earlyCandidates.count > 8, let stale = earlyCandidates.keys.first(where: { $0 != viewer }) {
                    earlyCandidates[stale] = nil
                }
            }
        case "bye":
            earlyCandidates[viewer] = nil
            if peer?.viewer == viewer { closePeer() }
        default:
            break
        }
    }

    private func add(_ c: [String: Any], to peer: GlassesCameraPeer) {
        peer.addRemote(candidate: J.s(c["candidate"]), mid: c["sdpMid"] as? String,
                       index: Int32(J.i(c["sdpMLineIndex"])))
    }

    /// In order: a candidate never overtakes the answer.
    private func post(_ body: [String: Any], viewer: String) {
        guard let id = shareID, let origin else { return }
        var msg = body
        msg["from"] = "mac"
        if !viewer.isEmpty { msg["viewer"] = viewer }
        let previous = outbox
        outbox = Task {
            await previous?.value
            await ScreenAPI.postJSON(origin, "/api/screen/shares/\(id)/signal", msg)
        }
    }

    private func closePeer() {
        peer?.close()
        peer = nil
        peerState = nil
    }
}

/// When the last frame went into the camera (written from WebRTC's threads).
final class GlassesFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0

    func mark() {
        lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    func fresh(within seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return last > 0 && ProcessInfo.processInfo.systemUptime - last < seconds
    }
}
