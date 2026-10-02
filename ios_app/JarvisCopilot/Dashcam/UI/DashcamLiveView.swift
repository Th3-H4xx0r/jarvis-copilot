import AVFoundation
import SwiftUI

/// Where the live video comes from: `getmediainfo` gives `rtsp` (one URL) or `rtsps` (one per
/// lens); `getdeviceattr` gives the lens count and the current lens (protocol.md §3, §7).
struct DashcamLiveSource: Equatable {
    var urls: [URL]
    var lenses: Int
    var currentLens: Int
    var transport: String?

    /// One URL per lens: switching lenses is switching URLs.
    var switchesByURL: Bool { urls.count >= 2 }
    /// Several lenses behind one URL switch with `setparamvalue?param=switchcam`.
    var canSwitch: Bool { switchesByURL || lenses >= 2 }

    /// The order to try transports in: the vendor app streams over UDP unless `getmediainfo`'s
    /// `transport` says "tcp" (`N4/q.C0`, devApiType 10), and falls back to the other.
    var transports: [DashcamRTSPClient.Transport] {
        transport?.trimmingCharacters(in: .whitespaces).lowercased() == "tcp" ? [.tcp, .udp] : [.udp, .tcp]
    }

    /// The stream for lens `index` (`rtsps` is indexed by the current camera).
    func url(lens index: Int) -> URL? {
        switchesByURL ? urls[min(max(0, index), urls.count - 1)] : urls.first
    }

    static func parse(media: Any?, attr: Any?, host: String) -> DashcamLiveSource {
        let m = media as? [String: Any] ?? [:]
        let a = attr as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            return (v as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        func url(_ v: Any) -> String? {
            if let s = v as? String { return s }
            let d = v as? [String: Any]
            return (d?["url"] ?? d?["rtsp"]) as? String
        }
        var raw = (m["rtsps"] as? [Any] ?? []).compactMap(url)
        if raw.isEmpty, let one = m["rtsp"] as? String { raw = [one] }
        let urls = raw.compactMap { text -> URL? in
            guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["rtsp", "rtsps"].contains(c.scheme?.lowercased() ?? "") else { return nil }
            // Some firmware reports a placeholder address; the stream is on the camera we're talking to.
            if (c.host ?? "").isEmpty || c.host == "0.0.0.0" || c.host == "127.0.0.1" { c.host = host }
            return c.url
        }
        return DashcamLiveSource(
            // The vendor app's own fallback for Eeasy cameras (`RTSP_URL_SUFFIX_EEASY`).
            urls: urls.isEmpty ? [URL(string: "rtsp://\(host):554")].compactMap { $0 } : urls,
            lenses: max(1, int(a["camnum"]) ?? 1),
            currentLens: max(0, int(a["curcamid"]) ?? 0),
            transport: m["transport"].map { "\($0)" })
    }

    /// Asks the paired camera (or the debug host) for its stream.
    @MainActor
    static func load() async -> (source: DashcamLiveSource, camera: DashcamCamera?) {
        let setup = DashcamSetupStore.load()
        let camera = setup.flatMap { DashcamSync.shared.cameraFactory($0) }
        let host = camera?.http.base.host ?? setup?.base()?.host ?? DashcamDetect.candidates[0].host
        var media: Any?
        var attr: Any?
        if let viidure = camera as? ViidureCamera {
            // The vendor app logs on (`enterrecorder`) when its live page opens, then asks for the stream.
            let logon = await Self.attempt { try await viidure.call("enterrecorder") }
            DashcamLiveTrace.log("enterrecorder: \(Self.traceText(logon))")
            let mediaReply = await Self.attempt { try await viidure.call("getmediainfo") }
            DashcamLiveTrace.log("getmediainfo: \(Self.traceText(mediaReply))")
            media = try? mediaReply.get()
            let attrReply = await Self.attempt { try await viidure.call("getdeviceattr") }
            DashcamLiveTrace.log("getdeviceattr: \(Self.traceText(attrReply))")
            attr = try? attrReply.get()
        }
        let source = parse(media: media, attr: attr, host: host)
        DashcamLiveTrace.log("stream urls \(source.urls.map(\.absoluteString)) lenses \(source.lenses) current \(source.currentLens) transport \(source.transport ?? "-")")
        return (source, camera)
    }

    private static func attempt(_ f: () async throws -> Any?) async -> Result<Any?, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    private static func traceText(_ r: Result<Any?, Error>) -> String {
        switch r {
        case .success(let v):
            guard let v else { return "ok (no info)" }
            if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
                return String(decoding: d.prefix(1500), as: UTF8.self)
            }
            return "\(v)"
        case .failure(let e): return "ERROR \(e.localizedDescription)"
        }
    }
}

/// Runs one live session at a time and keeps the display fed.
@MainActor
final class DashcamLiveModel: ObservableObject {
    enum Status: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    @Published private(set) var status: Status = .connecting
    @Published private(set) var source: DashcamLiveSource?
    @Published private(set) var lens = 0
    @Published private(set) var switching = false

    let video = DashcamLiveVideoView()
    private var client: DashcamRTSPClient?
    private var camera: DashcamCamera?
    private var isOpen = false
    private var idleTimerWasDisabled = false
    /// The transport that last played, tried first on the next connect (lens switch, return
    /// from the background) so it doesn't sit through the other one's timeout again.
    private var preferredTransport: DashcamRTSPClient.Transport?

    var lensName: String { Self.lensName(lens) }
    var otherLensName: String { Self.lensName(source.map { (lens + 1) % lensCount($0) } ?? 0) }

    static func lensName(_ index: Int) -> String {
        ["Front", "Rear", "Inside"].indices.contains(index) ? ["Front", "Rear", "Inside"][index] : "Lens \(index + 1)"
    }

    private func lensCount(_ s: DashcamLiveSource) -> Int { max(2, s.switchesByURL ? s.urls.count : s.lenses) }

    func open() async {
        guard !isOpen else { return }
        isOpen = true
        DashcamLiveTrace.reset("live view")
        DashcamSync.shared.pauseForLive(true)
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        await connect(reload: true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        stopClient()
        DashcamSync.shared.pauseForLive(false)
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }

    func retry() async {
        preferredTransport = nil
        await connect(reload: true)
    }

    /// App backgrounded: the decoder and the socket go away anyway; reconnect on return.
    func suspend() { if isOpen { stopClient() } }
    func resume() async { if isOpen && client == nil && status != .connecting { await connect(reload: false) } }

    func switchLens() async {
        guard let source, source.canSwitch, !switching else { return }
        switching = true
        defer { switching = false }
        let next = (lens + 1) % lensCount(source)
        stopClient()
        status = .connecting
        // The app always tells the camera (`switchcam`), then plays `rtsps[index]` when there is
        // one URL per lens (E5/c.switchCamera + queryPreviewUrl).
        do {
            try await camera?.set("switchcam", "\(next)")
        } catch let error where !source.switchesByURL {
            status = .failed("Couldn't switch to the \(Self.lensName(next).lowercased()) camera: \(error.localizedDescription)")
            return
        } catch {}
        lens = next
        await connect(reload: false)
    }

    private var connectGeneration = 0

    /// One session at a time: the A4 serves a single RTSP client, and open() racing resume() started two.
    private func connect(reload: Bool) async {
        connectGeneration += 1
        let mine = connectGeneration
        stopClient()
        status = .connecting
        if reload || source == nil {
            let loaded = await DashcamLiveSource.load()
            guard isOpen, mine == connectGeneration else { return }
            source = loaded.source
            camera = loaded.camera
            lens = loaded.source.currentLens
        }
        guard isOpen, let source, let url = source.url(lens: lens) else { return }
        play(url, transports: preferredTransport.map { [$0, $0.other] } ?? source.transports)
    }

    private func play(_ url: URL, transports: [DashcamRTSPClient.Transport]) {
        video.flush()
        let c = DashcamRTSPClient(url: url, transports: transports)
        c.onState = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                guard let self, let c, self.client === c else { return }
                switch state {
                case .connecting: self.status = .connecting
                case .playing:
                    self.status = .playing
                    self.preferredTransport = c.activeTransport
                case .failed(let message): self.status = .failed(message); self.client = nil
                }
            }
        }
        c.onFrame = { [weak self, weak c] frame in
            MainActor.assumeIsolated {
                guard let self, let c, self.client === c else { return }
                if !self.video.enqueue(frame) { c.requestKeyframe() }
            }
        }
        client = c
        c.start()
    }

    private func stopClient() {
        client?.stop()
        client = nil
    }
}

/// A view whose layer is the AVSampleBufferDisplayLayer the frames go to.
final class DashcamLiveVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows a frame. False when the decoder had stopped (e.g. after the app was in the
    /// background) and this delta frame was dropped: the stream must restart at a keyframe.
    @discardableResult
    func enqueue(_ frame: CMSampleBuffer) -> Bool {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: false) as? [[String: Any]]
            guard attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true else { return false }
        }
        renderer.enqueue(frame)
        return true
    }

    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

private struct DashcamLiveVideo: UIViewRepresentable {
    let view: DashcamLiveVideoView
    func makeUIView(context: Context) -> DashcamLiveVideoView { view }
    func updateUIView(_ uiView: DashcamLiveVideoView, context: Context) {}
}

/// Full-screen live picture from the dashcam (over its Wi‑Fi, RTSP). Syncing waits while it's open.
struct DashcamLiveView: View {
    @StateObject private var model = DashcamLiveModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            JcTheme.bg.ignoresSafeArea()
            DashcamLiveVideo(view: model.video)
                .ignoresSafeArea()
                .accessibilityLabel("Live view from the \(model.lensName.lowercased()) camera")
            statusOverlay
        }
        .overlay(alignment: .top) { topBar }
        .preferredColorScheme(.dark)
        .task { await model.open() }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.suspend()
            case .active: Task { await model.resume() }
            default: break
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                model.close()
                dismiss()
            } label: {
                JcIcon("xmark", size: 16)
            }
            .buttonStyle(.jcGlass(compact: true))
            .accessibilityLabel("Close live view")

            if model.status == .playing {
                HStack(spacing: 6) {
                    Circle().fill(JcTheme.danger).frame(width: 8, height: 8)
                    Text("LIVE").font(.caption.weight(.bold)).tracking(1)
                    if model.source?.canSwitch == true {
                        Text("· \(model.lensName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
            }

            Spacer()

            if model.source?.canSwitch == true {
                Button {
                    Task { await model.switchLens() }
                } label: {
                    HStack(spacing: 6) {
                        if model.switching { ProgressView().controlSize(.small) } else { JcIcon("arrow.triangle.2.circlepath", size: 15) }
                        Text(model.otherLensName)
                    }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(model.switching)
                .accessibilityLabel("Switch to the \(model.otherLensName.lowercased()) camera")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.status {
        case .playing:
            EmptyView()
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(JcTheme.text)
                Text("Connecting to the camera…").font(.callout).foregroundStyle(JcTheme.muted)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                JcIcon("wifi.exclamationmark", size: 28).foregroundStyle(JcTheme.muted)
                Text("No live picture").font(.headline).foregroundStyle(JcTheme.text)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await model.retry() } }
                    .buttonStyle(.jcGlass(compact: true))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 32)
        }
    }
}
