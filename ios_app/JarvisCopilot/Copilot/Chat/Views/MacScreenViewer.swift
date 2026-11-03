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

    private let api: JarvisAPI
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var pollTask: Task<Void, Never>?
    private var afterSeq = 0
    /// A share this viewer started for "anytime": stopping the viewer ends it.
    private var ownsShare = false

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init(shareID: String? = nil, api: JarvisAPI = .shared) {
        self.shareID = shareID
        self.api = api
    }

    // MARK: Start / stop

    /// Starts an anytime share, or joins the task share this viewer was made for.
    func start() async {
        guard phase == .idle || phase == .ended || isFailed else { return }
        phase = .connecting
        afterSeq = 0
        do {
            var ice: [[String: Any]] = []
            if let shareID {
                let share = try await api.get("/api/screen/shares/\(shareID)", timeout: 20).object()
                if share["status"] as? String == "ended" {
                    phase = .ended
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
                ice = share["ice_servers"] as? [[String: Any]] ?? []
            }
            try await connect(iceServers: ice)
        } catch {
            phase = .failed(apiErrorMessage(error))
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        if let shareID, pc != nil {
            _ = try? await api.post("/api/screen/shares/\(shareID)/signal", json: ["from": "viewer", "type": "bye"])
            if ownsShare { _ = try? await api.post("/api/screen/shares/\(shareID)/stop") }
        }
        channel?.close()
        pc?.close()
        channel = nil
        pc = nil
        track = nil
        phase = .ended
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
        _ = try await api.post("/api/screen/shares/\(shareID)/signal", json: message, timeout: 20)
    }

    private func poll() async {
        while !Task.isCancelled, let shareID, phase == .connecting || phase == .live {
            do {
                let reply = try await api.get("/api/screen/shares/\(shareID)/signal",
                                              query: ["for": "viewer", "after": "\(afterSeq)"],
                                              timeout: 35).object()
                for message in reply["messages"] as? [[String: Any]] ?? [] {
                    afterSeq = max(afterSeq, message["seq"] as? Int ?? afterSeq)
                    await handle(message)
                }
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
            guard let sdp = message["sdp"] as? String else { return }
            try? await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        case "candidate":
            guard let c = message["candidate"] as? [String: Any],
                  let line = c["candidate"] as? String else { return }
            try? await pc.add(RTCIceCandidate(sdp: line, sdpMLineIndex: Int32(c["sdpMLineIndex"] as? Int ?? 0),
                                              sdpMid: c["sdpMid"] as? String))
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

    fileprivate func iceChanged(_ state: RTCIceConnectionState) {
        switch state {
        case .failed: phase = .failed("Couldn't reach the Mac")
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

    init(shareID: String) {
        _session = State(initialValue: MainActor.assumeIsolated { MacScreenSession(shareID: shareID) })
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
                MacScreenPreview(session: session)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { if session.phase == .live { fullScreen = true } }
            }
        }
        .task { await session.start() }
        .onDisappear { Task { await session.stop() } }
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
                    Text(session.macOnline ? "Connecting to your Mac…" : "Waiting for your Mac…")
                        .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center).padding()
            case .ended:
                if session.track == nil {
                    Text("The share has ended.").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
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
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                            click(at: tap.location, container: geo.size, count: 2)
                        })
                        .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { tap in
                            click(at: tap.location, container: geo.size, count: 1)
                        })
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
                session.send(["t": "move", "x": p.x, "y": p.y])
            }
            .onEnded { value in
                let p = macScreenNormalised(value.location, video: session.videoSize, in: container)
                session.send(["t": "up", "x": p?.x ?? 0, "y": p?.y ?? 0, "button": "left"])
                dragging = false
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
