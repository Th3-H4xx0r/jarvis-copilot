import AVKit
import Observation
import SwiftUI
import WebKit

/// A browser task in the chat: which engine it runs on (Lightpanda, the server's
/// Chrome or a cloud browser), the cloud browser's live view while it runs — tap
/// for full screen, Take over to drive it yourself, Hand back to let Jarvis carry
/// on — and its replay once it ends. A Lightpanda task can be moved to the cloud.
struct BrowserSessionCard: View {
    let sessionID: String
    /// Sends a chat message (used when the move button is pressed between turns).
    var onSend: ((String) -> Void)?

    @State private var model: BrowserSessionModel
    @State private var fullScreen = false

    init(sessionID: String, onSend: ((String) -> Void)? = nil) {
        self.sessionID = sessionID
        self.onSend = onSend
        _model = State(initialValue: MainActor.assumeIsolated { BrowserSessionModel(id: sessionID) })
    }

    var body: some View {
        JcCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let session = model.session {
                    content(session)
                    if let error = model.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(JcTheme.amber)
                    }
                } else if let error = model.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 40)
                }
            }
        }
        .task { await model.watch() }
        .fullScreenCover(isPresented: $fullScreen) {
            BrowserLiveSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            JcIconSquare(symbol: model.session?.engine == "cloud" ? "globe" : "safari")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session.map { $0.title.isEmpty ? "Browser" : $0.title } ?? "Browser")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(model.session?.host ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let session = model.session {
                StatusPill(session.engineLabel,
                           color: session.engine == "cloud" ? JcTheme.accent : JcTheme.muted,
                           live: session.isRunning && session.engine == "cloud", dense: true)
            }
        }
    }

    @ViewBuilder
    private func content(_ session: BrowserSession) -> some View {
        if session.isRunning, let live = session.liveURL {
            BrowserLiveWebView(url: live, interactive: false)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .padding(7)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
                .contentShape(Rectangle())
                .onTapGesture { fullScreen = true }
            if session.takeover {
                Text("You're in control. Hand back when you're done.")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.amber)
            }
        } else if !session.isRunning, session.replayStatus == "ready" {
            BrowserReplayView(model: model)
        } else if !session.isRunning, session.replayStatus == "encoding" || session.replayStatus == "recording" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the replay…").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
        }

        if session.canMoveToCloud, session.engine != "cloud" {
            HStack(spacing: 10) {
                Text(session.engine == "lightpanda"
                     ? "Lightpanda is fast but has no picture."
                     : "Running in the server's Chrome.")
                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                JcSmallAction(session.moveRequested ? "Moving…" : "Run on cloud browser", symbol: "cloud",
                              busy: model.moving) {
                    Task {
                        if let turnRunning = await model.moveToCloud(), !turnRunning {
                            onSend?("Continue that on the cloud browser.")
                        }
                    }
                }
                .disabled(!session.cloudReady || session.moveRequested)
            }
            if !session.cloudReady, let hint = session.cloudHint {
                Text(hint).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
            }
        }
        if session.isRunning, session.engine == "cloud", session.interactiveURL != nil {
            HStack {
                JcSmallAction(session.takeover ? "Hand back to Jarvis" : "Take over",
                              symbol: session.takeover ? "arrow.uturn.backward" : "hand.point.up.left",
                              busy: model.switching) {
                    let takingOver = !session.takeover
                    Task {
                        if await model.setTakeover(takingOver), takingOver { fullScreen = true }
                    }
                }
                Spacer()
            }
        }
    }

    /// The card's session id, out of a browser tool's result
    /// (`"card": {"kind": "browser_session", "session": "…"}`).
    static func sessionID(in tool: ToolInvocation) -> String? {
        for text in [tool.result, tool.preview].compactMap({ $0 }) {
            guard let kind = text.range(of: "\"browser_session\"") else { continue }
            let tail = text[kind.upperBound...]
            guard let key = tail.range(of: "\"session\"") else { continue }
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

// MARK: - Model

struct BrowserSession: Equatable {
    var id: String
    var engine: String
    var providerName: String?
    var status: String
    var url: String
    var title: String
    var liveURL: URL?
    var interactiveURL: URL?
    var takeover: Bool
    var moveRequested: Bool
    var replayURL: String?
    var replayStatus: String
    var cloudReady: Bool
    var cloudHint: String?
    var canMoveToCloud: Bool

    var isRunning: Bool { status == "running" }
    var host: String { URL(string: url)?.host() ?? url }
    var engineLabel: String {
        switch engine {
        case "cloud": return "Cloud · \(providerName ?? "browser")"
        case "chrome": return "Server Chrome"
        default: return "Lightpanda"
        }
    }

    init(json: [String: Any]) {
        func s(_ k: String) -> String? { (json[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        id = s("id") ?? ""
        engine = s("engine") ?? "lightpanda"
        providerName = s("provider_name")
        status = s("status") ?? "running"
        url = s("url") ?? ""
        title = s("title") ?? ""
        liveURL = s("live_url").flatMap(URL.init(string:))
        interactiveURL = s("live_interactive_url").flatMap(URL.init(string:))
        takeover = json["takeover"] as? Bool ?? false
        moveRequested = json["move_requested"] as? Bool ?? false
        replayURL = s("replay_url")
        replayStatus = s("replay_status") ?? "none"
        cloudReady = json["cloud_ready"] as? Bool ?? false
        cloudHint = s("cloud_hint")
        canMoveToCloud = json["can_move_to_cloud"] as? Bool ?? (status == "running" && engine != "cloud")
    }
}

@Observable
@MainActor
final class BrowserSessionModel {
    let id: String
    private let api: JarvisAPI
    private(set) var session: BrowserSession?
    private(set) var error: String?
    private(set) var moving = false
    private(set) var switching = false
    /// The replay, downloaded once (the endpoint needs the app's auth).
    private(set) var replayFile: URL?

    init(id: String, api: JarvisAPI = .shared) {
        self.id = id
        self.api = api
    }

    private var path: String {
        "/api/browser/sessions/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
    }

    /// Polls while the task runs (and until its replay is ready), then stops.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            guard let session else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            let settled = !session.isRunning && ["ready", "failed", "none"].contains(session.replayStatus)
            if settled {
                if session.replayStatus == "ready" { await loadReplay() }
                return
            }
            try? await Task.sleep(for: .seconds(session.isRunning ? 1.5 : 3))
        }
    }

    func refresh() async {
        do {
            session = BrowserSession(json: try await api.get(path, timeout: 20).object())
            error = nil
        } catch {
            if session == nil { self.error = apiErrorMessage(error) }
        }
    }

    /// Returns whether a turn is running (nil: the request failed).
    func moveToCloud() async -> Bool? {
        moving = true
        defer { moving = false }
        do {
            let reply = try await api.post("\(path)/move", json: ["to": "cloud"]).object()
            await refresh()
            return reply["turn_running"] as? Bool ?? true
        } catch {
            self.error = apiErrorMessage(error)
            return nil
        }
    }

    /// Returns whether the switch took (the server refuses on an ended / non-cloud session).
    @discardableResult
    func setTakeover(_ active: Bool) async -> Bool {
        switching = true
        defer { switching = false }
        do {
            _ = try await api.post("\(path)/takeover", json: ["active": active])
            error = nil
            await refresh()
            return true
        } catch {
            self.error = apiErrorMessage(error)
            await refresh()
            return false
        }
    }

    func loadReplay() async {
        guard replayFile == nil, let path = session?.replayURL else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-replay-\(id.replacingOccurrences(of: "/", with: "_")).mp4")
        if FileManager.default.fileExists(atPath: file.path) {
            replayFile = file
            return
        }
        guard let data = try? await api.get(path, timeout: 180).data, !data.isEmpty else { return }
        try? data.write(to: file, options: .atomic)
        replayFile = file
    }
}

// MARK: - Views

/// A provider's live view. Read-only: touches don't reach the page; interactive:
/// the page takes taps and the keyboard.
struct BrowserLiveWebView: UIViewRepresentable {
    let url: URL
    let interactive: Bool

    final class Coordinator { var requested: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = interactive
        view.isUserInteractionEnabled = interactive
        view.load(URLRequest(url: url))
        context.coordinator.requested = url
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        view.scrollView.isScrollEnabled = interactive
        // Reload only when a different view is asked for (the viewer may rewrite its
        // own URL; comparing against that would reload it on every poll).
        if context.coordinator.requested != url {
            context.coordinator.requested = url
            view.load(URLRequest(url: url))
        }
    }
}

private struct BrowserReplayView: View {
    let model: BrowserSessionModel
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ZStack {
                    Color.black
                    ProgressView()
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: model.replayFile) {
            if let file = model.replayFile { player = AVPlayer(url: file) }
        }
    }
}

/// Full screen: the live view, Take over / Hand back, Done.
private struct BrowserLiveSheet: View {
    let model: BrowserSessionModel
    @Environment(\.dismiss) private var dismiss

    private var shownURL: URL? {
        guard let session = model.session else { return nil }
        return session.takeover ? (session.interactiveURL ?? session.liveURL) : session.liveURL
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let live = shownURL, model.session?.isRunning == true {
                    BrowserLiveWebView(url: live, interactive: model.session?.takeover == true)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("The browser has closed.").foregroundStyle(JcTheme.muted)
                }
            }
            .navigationTitle(model.session?.host ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let session = model.session, session.isRunning {
                        Button(session.takeover ? "Hand back" : "Take over") {
                            Task { await model.setTakeover(!session.takeover) }
                        }
                        .tint(JcTheme.accent)
                    }
                }
            }
        }
        .task {
            // Keep the sheet's copy current while it's open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refresh()
            }
        }
    }
}
