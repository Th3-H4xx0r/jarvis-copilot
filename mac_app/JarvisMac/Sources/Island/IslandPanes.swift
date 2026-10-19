import AppKit
import SwiftUI

private let dim = Color.white.opacity(0.55)

/// Chat with Jarvis (or a model on this Mac) from the notch, laid out like the
/// phone's chat: your turns in a soft bubble, Jarvis's turns open with their
/// tools in one box, approvals and questions answered in place. Drop files on
/// it; ⌃⌥W adds the window you were in.
struct ChatPane: View {
    let ui: IslandUI
    @Bindable var chat = MacChatStore.shared
    @State private var options = ChatRunOptions.shared
    @FocusState private var focused: Bool

    private static let bottom = "chat-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Lazy: opening the island builds the turns on screen, not
                    // the whole conversation (that froze every open ~100 ms).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if chat.lines.isEmpty { empty }
                        ForEach(Array(chat.lines.enumerated()), id: \.element.id) { i, line in
                            // Same speaker: 6 pt; a change of speaker gets air.
                            let gap: CGFloat = i == 0 ? 0 : (chat.lines[i - 1].role == line.role ? 6 : 18)
                            row(line).padding(.top, gap).id(line.id)
                        }
                        if let a = chat.pendingApproval {
                            ChatApprovalCard(approval: a, error: chat.answerError) { chat.answerApproval($0) }
                                .padding(.top, 12)
                        }
                        if let c = chat.pendingClarify {
                            ChatClarifyCard(clarify: c, error: chat.answerError) { chat.answerClarify($0) }
                                .padding(.top, 12)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                // Opens on the latest turn and stays there as the reply grows.
                .defaultScrollAnchor(.bottom)
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onChange(of: scrollKey) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            composer
        }
        .onAppear {
            focused = true
            if chat.provider != .jarvis { chat.loadLocalModels() }
        }
        .onChange(of: chat.draft) { _, d in ui.pinned = !d.isEmpty || chat.busy }
        .onChange(of: chat.busy) { _, b in ui.pinned = b || !chat.draft.isEmpty }
        .onDisappear { ui.pinned = false }
    }

    /// Anything that grows the conversation keeps its end in view.
    private var scrollKey: [Int] {
        let last = chat.lines.last
        return [chat.lines.count, last?.turn.text.count ?? 0, last?.turn.tools.count ?? 0,
                last?.turn.tools.filter(\.done).count ?? 0, chat.pendingApproval == nil ? 0 : 1,
                chat.pendingClarify == nil ? 0 : 1]
    }

    @ViewBuilder private func row(_ line: MacChatStore.Line) -> some View {
        switch line.role {
        case .user: ChatUserBubble(line: line)
        case .assistant: ChatTurnView(turn: line.turn)
        case .note: ChatNoteRow(text: line.text)
        }
    }

    /// "Chat", then who answers and a new chat — the phone's header.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Chat").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if chat.provider != .jarvis, chat.localModels.isEmpty {
                Text(chat.localError ?? "Looking for models…")
                    .font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
            }
            Menu { menu } label: {
                HStack(spacing: 5) {
                    if chat.provider == .jarvis, let symbol = chat.runChoice.symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(JcAccent.color)
                    }
                    Text(modelLabel).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 190)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .chatGlass(in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Who answers")
            Button { chat.newChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcAccent.color).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New chat")
        }
    }

    @ViewBuilder private var menu: some View {
        Picker("Chat with", selection: $chat.provider) {
            ForEach(MacChatStore.Provider.allCases) { Text($0.label).tag($0) }
        }
        if chat.provider == .jarvis {
            Divider()
            choiceToggle("Chat default", .chatDefault)
            ForEach(options.harnesses) { h in choiceToggle(h.name, h.choice) }
            if !options.models.isEmpty {
                Menu("Single model") {
                    ForEach(options.providers, id: \.self) { p in
                        Menu(p.isEmpty ? "Models" : p) {
                            ForEach(options.models(for: p)) { m in choiceToggle(m.label, m.choice) }
                        }
                    }
                }
            }
            Divider()
            Button("Chat settings…") { SettingsWindow.show(model: AppModel.shared) }
        } else if !chat.localModels.isEmpty {
            Divider()
            Picker("Model", selection: $chat.localModel) {
                ForEach(chat.localModels, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func choiceToggle(_ title: String, _ choice: ChatRunChoice) -> some View {
        Toggle(title, isOn: Binding(get: { chat.runChoice == choice }, set: { if $0 { chat.runChoice = choice } }))
    }

    private var modelLabel: String {
        if chat.provider == .jarvis { return chat.runChoice.label }
        return chat.localModel.isEmpty ? chat.provider.label : "\(chat.provider.label) · \(chat.localModel)"
    }

    /// A new chat: the orb and the question, like the phone's.
    private var empty: some View {
        VStack(spacing: 10) {
            OrbView(mood: .idle, skin: OrbSkin.current, size: 52)
                .padding(.bottom, 12)
            Text("What\u{2019}s on your mind?")
                .font(.system(size: 18, weight: .medium)).tracking(-0.4).foregroundStyle(.white)
            Text("A question, a plan, or the next thing to get done.")
                .font(.system(size: 12.5)).foregroundStyle(dim)
            Text("Drop files here, or press \u{2303}\u{2325}W to add the window you\u{2019}re in.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    /// Where Send goes: an open question takes your words as its answer.
    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!chat.busy || answering) }
    private var answering: Bool { chat.pendingClarify != nil }
    private var canStop: Bool { chat.busy && !answering }

    /// The phone's composer: one glass field — what's attached above the text,
    /// attach, the message, send (stop while Jarvis works) — its edge lit while
    /// Jarvis answers.
    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            if chat.window != nil || !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let w = chat.window {
                            ContextChip(icon: "macwindow", text: w.title.isEmpty ? w.app : "\(w.app) — \(w.title)") {
                                chat.clearWindow()
                            }
                        }
                        ForEach(chat.attachments) { a in
                            ContextChip(icon: a.isImage ? "photo" : "doc", text: a.name,
                                        detail: ChatContext.sizeText(a.size), thumbnail: a.isImage ? a.url : nil) {
                                chat.remove(a)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button { attach() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .chatGlass(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Attach files")
                TextField(answering ? "Type your answer" : "Message Jarvis", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: ChatStyle.body)).foregroundStyle(ChatStyle.text)
                    .lineLimit(1...6).focused($focused)
                    .padding(.vertical, 8)
                    .onSubmit { chat.send() }
                Button { canStop ? chat.stop() : chat.send() } label: {
                    Image(systemName: canStop ? "stop.fill" : "arrow.up").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canStop ? .white : (canSend ? JcAccent.color : .white.opacity(0.35)))
                        .frame(width: 34, height: 34)
                        .chatGlass(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStop && !canSend)
                .help(canStop ? "Stop" : "Send")
            }
        }
        .padding(6)
        .chatGlass(in: shape)
        // The edge lights only while Jarvis is working on a reply.
        .overlay(shape.strokeBorder(JcAccent.color.opacity(chat.busy ? 0.6 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: chat.busy)
    }

    private func attach() {
        let panel = ChatAttachPanel.make()
        ui.pinned = true
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated {
                if response == .OK { chat.attach(panel.urls) }
                ui.pinned = !chat.draft.isEmpty || chat.busy
            }
        }
    }
}

/// Something going with the next message: the phone's attachment chip
/// (a picture's thumbnail, the name, its size, ×).
private struct ContextChip: View {
    let icon: String
    let text: String
    var detail: String? = nil
    var thumbnail: URL? = nil
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(dim)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                if let detail { Text(detail).font(.system(size: 8.5)).foregroundStyle(dim) }
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(dim)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove")
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.leading, thumbnail == nil ? 9 : 4).padding(.trailing, 3).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

/// Talking to Jarvis in the notch: jc-client's voice panel (orb, transcript,
/// mute / start / send) in its island layout — one stage the island's width. It holds
/// the microphone while it's up, so "Hey Jarvis" steps aside; the island stays
/// open while it's showing (IslandPin).
struct VoicePane: View {
    let ui: IslandUI
    let make: (() -> NSViewController?)?
    /// The stage's height, or the small island's band.
    var height: CGFloat = IslandLayout.voicePanelHeight
    /// Made once when the view appears (it starts a voice session), not per render.
    @State private var panel: NSViewController?
    @State private var tried = false
    /// For the orb's flight: the stage's orb as the panel reports it across the
    /// dylib (`VoicePanelOrb`) — in SwiftUI's global space, which for a hosting
    /// view nested in this window is the window's — and how far the island's
    /// space sits from that.
    @State private var globalToIsland: CGSize?
    @State private var orbGlobal: CGRect?

    var body: some View {
        // Always the panel's size, even before the panel exists: an empty view
        // never appears, and then the panel would never be made.
        ZStack {
            if let panel {
                VoicePanelHost(controller: panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onGeometryChange(for: CGSize.self) { g in
                        let island = g.frame(in: .named(IslandRootView.space)), global = g.frame(in: .global)
                        return CGSize(width: island.minX - global.minX, height: island.minY - global.minY)
                    } action: {
                        globalToIsland = $0
                        reportOrb()
                    }
            } else if tried {
                Text("The voice panel isn't available — is jc-client running?")
                    .font(.system(size: 12)).foregroundStyle(dim)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .onAppear {
            if panel == nil { panel = make?() }
            tried = true
            NotificationCenter.default.post(name: .jarvisVoicePanelOpened, object: nil)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .jarvisVoicePanelClosed, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: VoicePanelOrb.frameNotification)) { note in
            guard let value = note.userInfo?["frame"] as? NSValue else { return }
            orbGlobal = value.rectValue
            reportOrb()
        }
    }

    /// Where the stage's orb is in the island: the flight's home for Voice.
    private func reportOrb() {
        guard let globalToIsland, let orbGlobal else { return }
        ui.reportOrbHome(.voice, orbGlobal.offsetBy(dx: globalToIsland.width, dy: globalToIsland.height))
    }
}

private struct VoicePanelHost: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ vc: NSViewController, context: Context) {}
}

/// What Apple Music or Spotify is playing, laid out like Apple's Now Playing:
/// the cover with title and artist (a live waveform and the player's icon on
/// the right), a thin progress bar between elapsed and remaining time, then
/// the transport in the middle with shuffle and repeat on the left and volume
/// on the right. Every row is pinned to IslandLayout.Music, so the island is
/// exactly as tall as this.
struct MusicPane: View {
    @Bindable var music = MusicController.shared

    var body: some View {
        NowPlayingCard(now: music.now, shuffle: music.shuffle, repeating: music.repeating,
                       volume: $music.volume, send: { music.send($0) })
            .onAppear { music.setVisible(true) }
            .onDisappear { music.setVisible(false) }
    }
}

/// The Now Playing card itself, fed its values so it can be rendered on its own.
struct NowPlayingCard: View {
    let now: NowPlaying?
    let shuffle: Bool
    let repeating: Bool
    @Binding var volume: Double
    let send: @MainActor (MusicScript.Command) -> Void
    @State private var scrub: Double?
    private typealias L = IslandLayout.Music

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: L.gap) {
                header
                progress(at: ctx.date)
                controls
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncImage(url: now?.artworkURL) { img in img.resizable().scaledToFill() } placeholder: {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note").font(.system(size: 20, weight: .medium)).foregroundStyle(dim)
                }
            }
            .frame(width: L.artwork, height: L.artwork)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(now?.title ?? "Not Playing")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(now.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "Music or Spotify")
                    .font(.system(size: 12)).foregroundStyle(dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let now {
                MusicBars(playing: now.isPlaying).frame(width: 18, height: 16)
                PlayerIcon(player: now.player)
            }
        }
        .frame(height: L.artwork)
    }

    private func progress(at date: Date) -> some View {
        let duration = now?.duration ?? 0
        let position = scrub ?? now?.position(at: date) ?? 0
        return HStack(spacing: 10) {
            Text(now == nil ? "--:--" : NowPlaying.clock(position)).frame(width: 44, alignment: .leading)
            ThinBar(value: duration > 0 ? position / duration : 0, enabled: now != nil && duration > 0) { f, done in
                if done { send(.seek(f * duration)); scrub = nil } else { scrub = f * duration }
            }
            Text(now == nil ? "--:--" : NowPlaying.remaining(duration, position)).frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(dim)
        .frame(height: L.progress)
    }

    private var controls: some View {
        ZStack {
            HStack(spacing: 6) {
                toggle("shuffle", on: shuffle, help: "Shuffle") { send(.shuffle(!shuffle)) }
                toggle("repeat", on: repeating, help: "Repeat") { send(.repeating(!repeating)) }
                Spacer()
                Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(dim)
                ThinBar(value: volume / 100) { f, _ in volume = (f * 100).rounded() }
                    .frame(width: 84)
                    .help("Volume")
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundStyle(dim)
            }
            HStack(spacing: 26) {
                transport("backward.fill", size: 17, help: "Previous") { send(.previous) }
                transport(now?.isPlaying == true ? "pause.fill" : "play.fill", size: 24,
                          help: now?.isPlaying == true ? "Pause" : "Play") { send(.playPause) }
                transport("forward.fill", size: 17, help: "Next") { send(.next) }
            }
        }
        .frame(height: L.controls)
        .disabled(now == nil)
        .opacity(now == nil ? 0.4 : 1)
    }

    private func transport(_ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: L.controls)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help).accessibilityLabel(help)
    }

    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? JcAccent.color : .white.opacity(0.55))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? JcAccent.color.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help).accessibilityLabel(help).accessibilityValue(on ? "On" : "Off")
    }
}

/// Apple's thin bar: a faint track with a white fill that thickens while you
/// hover or drag it. Dragging reports the fraction, and `done` on release.
private struct ThinBar: View {
    let value: Double
    var enabled = true
    let onChange: (Double, Bool) -> Void
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let thick: CGFloat = enabled && (hover || dragging) ? 7 : 4
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(enabled ? 0.92 : 0.35)).frame(width: g.size.width * fraction)
            }
            .frame(height: thick)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard enabled else { return }
                    dragging = true
                    onChange(min(max(v.location.x / max(g.size.width, 1), 0), 1), false)
                }
                .onEnded { v in
                    guard enabled else { return }
                    dragging = false
                    onChange(min(max(v.location.x / max(g.size.width, 1), 0), 1), true)
                })
            .animation(.easeOut(duration: 0.15), value: thick)
        }
        .onHover { hover = $0 }
    }
}

/// The live waveform Apple shows next to what's playing: four bars that move
/// while it plays and settle when it pauses.
private struct MusicBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(JcAccent.color)
                        .frame(width: 3, height: playing ? 4 + 12 * abs(sin(t * (2.2 + Double(i) * 0.65) + Double(i))) : 3)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.1), value: t)
        }
    }
}

/// The playing app's own icon; a click brings that app forward.
private struct PlayerIcon: View {
    let player: NowPlaying.Player

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) {
            Button { NSWorkspace.shared.openApplication(at: url, configuration: .init()) } label: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            }
            .buttonStyle(PressStyle())
            .help("Open \(player.app)").accessibilityLabel("Open \(player.app)")
        }
    }
}

/// A small press-down for icon buttons.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The chat's "+" file picker. Over the island (main menu + 3): at the normal
/// level the island covered it. Opened with `begin` (not `runModal`, which
/// puts a panel back at the modal level).
enum ChatAttachPanel {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)

    @MainActor
    static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.level = level
        return panel
    }
}
