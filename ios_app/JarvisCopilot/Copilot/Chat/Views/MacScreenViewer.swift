import AVKit
import Observation
import SwiftUI
import WebRTC

/// The Mac's screen, live over WebRTC: the Mac app answers with its display as a
/// video track; this side offers (receive-only video + an "input" data channel)
/// and, in full screen, turns taps, drags and typing into input events the Mac app
/// injects. Signaling goes through the Jarvis server (long-polled); video goes peer
/// to peer, or through the server's TURN relay when it must.
@Observable
@MainActor
final class MacScreenSession: NSObject {
    enum Phase: Equatable { case idle, connecting, live, ended, failed(String) }

    private(set) var shareID: String?
    private(set) var phase: Phase = .idle
    private(set) var macOnline = true
    /// The Mac's display size, from the first frame (for aspect + coordinates).
    private(set) var videoSize: CGSize = .zero
    private(set) var track: RTCVideoTrack?
    /// The share's replay once it has ended and the Mac uploaded it.
    private(set) var replayURL: String?
    private(set) var replayFile: URL?

    private let api: JarvisAPI
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var pollTask: Task<Void, Never>?
    private var afterSeq = 0
    /// A share this viewer started for "anytime": stopping the viewer ends it.
    private var ownsShare = false
    /// Find the running computer task's share (the card shows while the task runs,
    /// before its result — which carries the id — exists).
    private let findsTaskShare: Bool
    /// This connection's id on the share: the Mac answers per viewer, so an old
    /// connection's bye or answer never lands on this one.
    private var viewerID = "ios-\(UUID().uuidString.prefix(8).lowercased())"
    /// Remote candidates that arrived before the answer was applied.
    private var pendingCandidates: [RTCIceCandidate] = []
    private var remoteSet = false

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init(shareID: String? = nil, findsTaskShare: Bool = false, api: JarvisAPI = .shared) {
        self.shareID = shareID
        self.findsTaskShare = findsTaskShare
        self.api = api
    }

    // MARK: Start / stop

    /// Starts an anytime share, or joins the task share this viewer was made for.
    func start() async {
        guard phase == .idle || phase == .ended || isFailed else { return }
        phase = .connecting
        afterSeq = 0
        remoteSet = false
        pendingCandidates = []
        viewerID = "ios-\(UUID().uuidString.prefix(8).lowercased())"
        do {
            var ice: [[String: Any]] = []
            if shareID == nil, findsTaskShare {
                guard let found = await findTaskShare() else {
                    phase = .failed("No live share for this task")
                    return
                }
                shareID = found
            }
            if let shareID {
                let share = try await api.get("/api/screen/shares/\(shareID)", timeout: 20).object()
                if share["status"] as? String == "ended" {
                    await ended(share)
                    return
                }
                macOnline = share["mac_online"] as? Bool ?? true
                ice = (try? await api.get("/api/screen/ice", timeout: 20).object()["ice_servers"]
                       as? [[String: Any]]) ?? []
            } else {
                let share = try await api.post("/api/screen/shares", json: ["reason": "anytime"],
                                               timeout: 30).object()
                guard let id = share["id"] as? String else { throw APIError.badResponse("no share id") }
                shareID = id
                ownsShare = true
                macOnline = share["mac_online"] as? Bool ?? true
                ice = share["ice_servers"] as? [[String: Any]] ?? []
            }
            try await connect(iceServers: ice)
        } catch {
            phase = .failed(apiErrorMessage(error))
        }
    }

    /// The newest active task share (a computer task runs one at a time).
    private func findTaskShare() async -> String? {
        for _ in 0..<20 {
            if let reply = try? await api.get("/api/screen/shares", query: ["active": "1"], timeout: 15).object() {
                let shares = (reply["shares"] as? [[String: Any]] ?? []).filter { $0["reason"] as? String == "task" }
                if let newest = shares.max(by: { ($0["created_at"] as? String ?? "") < ($1["created_at"] as? String ?? "") }),
                   let id = newest["id"] as? String {
                    return id
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return nil
    }

    /// An ended share: show its replay when the Mac uploaded one.
    private func ended(_ share: [String: Any]) async {
        phase = .ended
        replayURL = (share["replay_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let path = replayURL, replayFile == nil, let shareID else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mac-replay-\(shareID).mp4")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? await api.get(path, timeout: 180).data, !data.isEmpty else { return }
            try? data.write(to: file, options: .atomic)
        }
        replayFile = file
    }

    /// Re-reads an ended share until its replay arrives (the Mac uploads after the task).
    func awaitReplay() async {
        guard let shareID else { return }
        for _ in 0..<40 where replayFile == nil && phase == .ended {
            if let share = try? await api.get("/api/screen/shares/\(shareID)", timeout: 15).object() {
                await ended(share)
                if replayFile != nil { return }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func stop() async {
        // Tear down first, so a start() racing this sees .ended, not a stale .live.
        pollTask?.cancel()
        pollTask = nil
        let hadConnection = pc != nil
        channel?.close()
        pc?.close()
        channel = nil
        pc = nil
        track = nil
        phase = .ended
        if let shareID, hadConnection {
            _ = try? await api.post("/api/screen/shares/\(shareID)/signal",
                                    json: ["from": "viewer", "type": "bye", "viewer": viewerID])
            if ownsShare { _ = try? await api.post("/api/screen/shares/\(shareID)/stop") }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func connect(iceServers: [[String: Any]]) async throws {
        let config = RTCConfiguration()
        config.iceServers = iceServers.compactMap { server in
            let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server["username"] as? String,
                                credential: server["credential"] as? String)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw APIError.badResponse("WebRTC could not start")
        }
        self.pc = pc
        let video = RTCRtpTransceiverInit()
        video.direction = .recvOnly
        pc.addTransceiver(of: .video, init: video)
        let dc = RTCDataChannelConfiguration()
        dc.isOrdered = true
        channel = pc.dataChannel(forLabel: "input", configuration: dc)

        let offer = try await pc.offer(for: RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "true"], optionalConstraints: nil))
        try await pc.setLocalDescription(offer)
        try await signal(["type": "offer", "sdp": offer.sdp])
        pollTask = Task { [weak self] in await self?.poll() }
    }

    // MARK: Signaling

    private func signal(_ body: [String: Any]) async throws {
        guard let shareID else { return }
        var message = body
        message["from"] = "viewer"
        message["viewer"] = viewerID
        _ = try await api.post("/api/screen/shares/\(shareID)/signal", json: message, timeout: 20)
    }

    private func poll() async {
        while !Task.isCancelled, let shareID, phase == .connecting || phase == .live {
            do {
                let reply = try await api.get("/api/screen/shares/\(shareID)/signal",
                                              query: ["for": "viewer", "after": "\(afterSeq)", "viewer": viewerID],
                                              timeout: 35).object()
                for message in reply["messages"] as? [[String: Any]] ?? [] {
                    afterSeq = max(afterSeq, message["seq"] as? Int ?? afterSeq)
                    await handle(message)
                }
                // Ended on the server (e.g. after a restart, with no bye queued): stop.
                if reply["status"] as? String == "ended" {
                    await stop()
                    return
                }
                if phase == .connecting, let mac = reply["mac_online"] as? Bool { macOnline = mac }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handle(_ message: [String: Any]) async {
        guard let pc else { return }
        switch message["type"] as? String {
        case "answer":
            // Only the answer to this connection's offer (a stale one would win otherwise).
            guard let sdp = message["sdp"] as? String, pc.signalingState == .haveLocalOffer else { return }
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                remoteSet = true
                for candidate in pendingCandidates { try? await pc.add(candidate) }
                pendingCandidates = []
            } catch {
                phase = .failed("The Mac's answer didn't fit")
            }
        case "candidate":
            guard let c = message["candidate"] as? [String: Any],
                  let line = c["candidate"] as? String else { return }
            let candidate = RTCIceCandidate(sdp: line, sdpMLineIndex: Int32(c["sdpMLineIndex"] as? Int ?? 0),
                                            sdpMid: c["sdpMid"] as? String)
            if remoteSet { try? await pc.add(candidate) } else { pendingCandidates.append(candidate) }
        case "bye":
            await stop()
        default:
            break
        }
    }

    // MARK: Input

    /// Sends one input event to the Mac (coordinates normalised 0…1).
    func send(_ event: [String: Any]) {
        guard let channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func setVideoSize(_ size: CGSize) {
        if size.width > 0, size.height > 0 { videoSize = size }
    }

    fileprivate func attach(_ track: RTCVideoTrack) {
        self.track = track
        phase = .live
    }

    private var retries = 0

    fileprivate func iceChanged(_ state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed: retries = 0
        case .failed:
            // A Mac app relaunch, a network change, sleep: try a fresh connection a few times.
            guard retries < 3 else {
                phase = .failed("Couldn't reach the Mac")
                return
            }
            retries += 1
            let wait = Double(retries) * 2
            Task {
                await self.stop()
                try? await Task.sleep(for: .seconds(wait))
                await self.start()
            }
        case .closed: if phase == .live { phase = .ended }
        default: break
        }
    }

    fileprivate func sendCandidate(_ body: [String: Any]) {
        Task { try? await signal(body) }
    }
}

extension MacScreenSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                                    streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.attach(track) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let body: [String: Any] = ["type": "candidate",
                                   "candidate": ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "",
                                                 "sdpMLineIndex": Int(candidate.sdpMLineIndex)]]
        Task { @MainActor in self.sendCandidate(body) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in self.iceChanged(newState) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Video view

/// The remote track drawn with Metal, aspect-fit; reports the Mac's frame size.
struct MacScreenVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var onSize: (CGSize) -> Void = { _ in }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var onSize: (CGSize) -> Void = { _ in }
        weak var attached: RTCVideoTrack?
        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            DispatchQueue.main.async { self.onSize(size) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.onSize = onSize
        if context.coordinator.attached !== track {
            context.coordinator.attached?.remove(view)
            track?.add(view)
            context.coordinator.attached = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(view)
    }
}

/// Where the video actually sits inside a frame of `container` (aspect fit).
func macScreenContentRect(video: CGSize, in container: CGSize) -> CGRect {
    guard video.width > 0, video.height > 0, container.width > 0, container.height > 0 else {
        return CGRect(origin: .zero, size: container)
    }
    let scale = min(container.width / video.width, container.height / video.height)
    let size = CGSize(width: video.width * scale, height: video.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                  width: size.width, height: size.height)
}

/// A point in the container → normalised Mac coordinates (nil outside the picture).
func macScreenNormalised(_ point: CGPoint, video: CGSize, in container: CGSize) -> CGPoint? {
    let rect = macScreenContentRect(video: video, in: container)
    guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
    return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
}

// MARK: - Chat card

/// A computer task on the Mac, live in the chat (`"card": {"kind": "mac_screen"}`).
struct MacScreenCard: View {
    @State private var session: MacScreenSession
    @State private var fullScreen = false

    /// `shareID` nil: the running computer task's share, looked up live.
    init(shareID: String?) {
        _session = State(initialValue: MainActor.assumeIsolated {
            MacScreenSession(shareID: shareID, findsTaskShare: shareID == nil)
        })
    }

    var body: some View {
        JcCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    JcIconSquare(symbol: "desktopcomputer")
                    Text("Your Mac").font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                    Spacer()
                    StatusPill(session.phase.label,
                               color: session.phase == .live ? JcTheme.accent : JcTheme.muted,
                               live: session.phase == .live, dense: true)
                }
                if session.phase == .ended, let file = session.replayFile {
                    MacScreenReplay(file: file)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    MacScreenPreview(session: session)
                        .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                        .onTapGesture { if session.phase == .live { fullScreen = true } }
                }
            }
        }
        .task {
            await session.start()
            if session.phase == .ended { await session.awaitReplay() }
        }
        // Covering the card with its own full screen also "disappears" it; only a
        // card that really leaves (scrolled away, chat closed) hangs up.
        .onDisappear { if !fullScreen { Task { await session.stop() } } }
        .fullScreenCover(isPresented: $fullScreen) {
            MacScreenControlView(session: session, closesShare: false)
        }
    }

    static func shareID(in tool: ToolInvocation) -> String? {
        for text in [tool.result, tool.preview].compactMap({ $0 }) {
            guard let kind = text.range(of: "\"mac_screen\"") else { continue }
            let tail = text[kind.upperBound...]
            guard let key = tail.range(of: "\"share\"") else { continue }
            let rest = tail[key.upperBound...]
            guard let open = rest.firstIndex(of: "\""),
                  case let start = rest.index(after: open),
                  let close = rest[start...].firstIndex(of: "\"") else { continue }
            let value = String(rest[start..<close])
            if !value.isEmpty { return value }
        }
        return nil
    }
}

extension MacScreenSession.Phase {
    var label: String {
        switch self {
        case .idle, .connecting: return "Connecting"
        case .live: return "Live"
        case .ended: return "Ended"
        case .failed: return "Offline"
        }
    }
}

private struct MacScreenReplay: View {
    let file: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: file) } }
    }
}

/// The inline picture (watch only) with its waiting / failed states.
private struct MacScreenPreview: View {
    let session: MacScreenSession

    var body: some View {
        ZStack {
            Color.black
            if session.track != nil {
                MacScreenVideoView(track: session.track) { session.setVideoSize($0) }
                    .allowsHitTesting(false)
            }
            switch session.phase {
            case .idle, .connecting:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(session.macOnline ? "Connecting to your Mac…" : "Open Jarvis on your Mac to share its screen")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center).padding()
            case .ended:
                if session.track == nil, session.replayFile == nil {
                    Text(session.replayURL == nil ? "The share has ended." : "Loading the replay…")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            case .live:
                EmptyView()
            }
        }
    }
}

// MARK: - Full screen (watch + control)

/// Full screen: the Mac live, and control of it — tap to click, double-tap to
/// double-click, drag with the button held, the keyboard to type. `closesShare`:
/// an anytime share ends when this closes.
struct MacScreenControlView: View {
    let session: MacScreenSession
    var closesShare = true
    @Environment(\.dismiss) private var dismiss
    @State private var typing = ""
    @FocusState private var keyboard: Bool
    @State private var dragging = false
    @State private var lastDrag: CGPoint?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()
                    if session.phase == .live {
                        MacScreenVideoView(track: session.track) { session.setVideoSize($0) }
                    } else {
                        MacScreenPreview(session: session)
                    }
                    // Input layer over the picture.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(container: geo.size))
                        // One tap = click, double tap = double-click (never both).
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { tap in
                                click(at: tap.location, container: geo.size, count: 2)
                            }
                            .exclusively(before: SpatialTapGesture(count: 1).onEnded { tap in
                                click(at: tap.location, container: geo.size, count: 1)
                            }))
                    TextField("", text: $typing)
                        .focused($keyboard)
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: typing) { _, text in
                            guard !text.isEmpty else { return }
                            session.send(["t": "text", "text": text])
                            typing = ""
                        }
                        .onSubmit {
                            session.send(["t": "key", "key": "Return", "mods": [String]()])
                            keyboard = true
                        }
                }
            }
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { close() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { session.send(["t": "key", "key": "Escape", "mods": [String]()]) } label: {
                        Text("esc").font(.system(size: 14, weight: .semibold))
                    }
                    Button { session.send(["t": "key", "key": "Delete", "mods": [String]()]) } label: {
                        Image(systemName: "delete.left")
                    }
                    Button { keyboard.toggle() } label: { Image(systemName: "keyboard") }
                }
            }
        }
        .task { if session.phase == .idle { await session.start() } }
    }

    private func close() {
        if closesShare { Task { await session.stop() } }
        dismiss()
    }

    private func click(at point: CGPoint, container: CGSize, count: Int) {
        guard let p = macScreenNormalised(point, video: session.videoSize, in: container) else { return }
        session.send(["t": "click", "x": p.x, "y": p.y, "button": "left", "count": count])
    }

    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard let p = macScreenNormalised(value.location, video: session.videoSize, in: container) else { return }
                if !dragging,
                   let start = macScreenNormalised(value.startLocation, video: session.videoSize, in: container) {
                    dragging = true
                    session.send(["t": "down", "x": start.x, "y": start.y, "button": "left"])
                }
                guard dragging else { return }
                lastDrag = p
                session.send(["t": "move", "x": p.x, "y": p.y])
            }
            .onEnded { value in
                // A drag that never pressed sends no release; one leaving the picture
                // releases where it last was, never at the Mac's corner.
                if dragging, let p = macScreenNormalised(value.location, video: session.videoSize, in: container) ?? lastDrag {
                    session.send(["t": "up", "x": p.x, "y": p.y, "button": "left"])
                }
                dragging = false
                lastDrag = nil
            }
    }
}

// MARK: - Share button

/// "Share screen" on the Mac card: watch and control the Mac now.
struct MacShareScreenButton<Label: View>: View {
    @ViewBuilder var label: Label
    @State private var session: MacScreenSession?

    var body: some View {
        Button {
            session = MacScreenSession()
        } label: { label }
        .fullScreenCover(isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } })) {
            if let session { MacScreenControlView(session: session, closesShare: true) }
        }
    }
}
