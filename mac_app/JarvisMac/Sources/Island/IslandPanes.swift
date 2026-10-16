import AppKit
import SwiftUI

private let dim = Color.white.opacity(0.55)

/// Chat with Jarvis (or a model on this Mac) from the notch. Drop files on it;
/// ⌃⌥W adds the window you were in.
struct ChatPane: View {
    let ui: IslandUI
    @Bindable var chat = MacChatStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if chat.lines.isEmpty { empty }
                        ForEach(Array(chat.lines.enumerated()), id: \.element.id) { i, line in
                            // Same speaker: 6 pt; a change of speaker gets air.
                            let gap: CGFloat = i == 0 ? 0 : (chat.lines[i - 1].role == line.role ? 6 : 18)
                            ChatBubble(line: line).padding(.top, gap).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: chat.lines.last?.text) { _, _ in
                    if let id = chat.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            composer
        }
        .onAppear { focused = true; if chat.provider != .jarvis { chat.loadLocalModels() } }
        .onChange(of: chat.draft) { _, d in ui.pinned = !d.isEmpty || chat.busy }
        .onChange(of: chat.busy) { _, b in ui.pinned = b || !chat.draft.isEmpty }
        .onDisappear { ui.pinned = false }
    }

    /// "Chat", then the model and a new chat — the phone's header.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Chat").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if chat.provider != .jarvis, chat.localModels.isEmpty {
                Text(chat.localError ?? "Looking for models…")
                    .font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
            }
            Menu {
                Picker("Chat with", selection: $chat.provider) {
                    ForEach(MacChatStore.Provider.allCases) { Text($0.label).tag($0) }
                }
                if chat.provider != .jarvis, !chat.localModels.isEmpty {
                    Divider()
                    Picker("Model", selection: $chat.localModel) {
                        ForEach(chat.localModels, id: \.self) { Text($0).tag($0) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(modelLabel).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Who you're chatting with")
            Button { chat.newChat() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcAccent.color).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("New chat")
        }
    }

    private var modelLabel: String {
        if chat.provider == .jarvis { return "Jarvis" }
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

    /// One rounded glass field: attach, the message, send — what's attached sits
    /// inside it, and its edge lights while Jarvis answers.
    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if chat.window != nil || !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let w = chat.window {
                            ContextChip(icon: "macwindow", text: w.title.isEmpty ? w.app : "\(w.app) — \(w.title)") {
                                chat.clearWindow()
                            }
                        }
                        ForEach(chat.attachments) { a in
                            ContextChip(icon: a.isImage ? "photo" : "doc", text: a.name) { chat.remove(a) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Button { attach() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Attach files")
                TextField("Message Jarvis", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...5).focused($focused)
                    .padding(.vertical, 7)
                    .onSubmit { chat.send() }
                let canSend = !chat.draft.trimmingCharacters(in: .whitespaces).isEmpty
                Button { chat.busy ? chat.stop() : chat.send() } label: {
                    Image(systemName: chat.busy ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(chat.busy ? .white : (canSend ? JcAccent.color : .white.opacity(0.35)))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!chat.busy && !canSend)
                .help(chat.busy ? "Stop" : "Send")
            }
        }
        .padding(6)
        .background(shape.fill(Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(chat.busy ? JcAccent.color.opacity(0.6) : Color.white.opacity(0.10), lineWidth: chat.busy ? 1 : 0.5))
        .animation(.easeOut(duration: 0.2), value: chat.busy)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        if panel.runModal() == .OK { chat.attach(panel.urls) }
    }
}

private struct ChatBubble: View {
    let line: MacChatStore.Line

    var body: some View {
        switch line.role {
        case .user:
            // The phone's: a restrained blue surface hugged to the right.
            HStack {
                Spacer(minLength: 70)
                Text(line.text).font(.system(size: 13.5)).lineSpacing(2).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(JcAccent.soft.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(JcAccent.soft.opacity(0.14), lineWidth: 0.5))
            }
        case .assistant:
            Group {
                if line.text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.system(size: 12)).foregroundStyle(dim)
                    }
                } else {
                    Text(Self.markdown(line.text)).font(.system(size: 13.5)).lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(line.text, systemImage: "wrench.and.screwdriver").font(.system(size: 11)).foregroundStyle(dim)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct ContextChip: View {
    let icon: String
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1).frame(maxWidth: 200)
            Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.1)))
    }
}

/// Stripe, GitHub, Vercel, n8n, Notion, Cal.com, Resend — and the portfolio.
struct ServicesPane: View {
    let model: AppModel
    @State private var open: String?

    var body: some View {
        let cards = MacServiceCard.sorted(model.services.map(MacServiceCard.init(json:)))
        let folio = MacPortfolio(json: model.portfolio)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                if cards.isEmpty && folio.isEmpty {
                    Text("No services yet. Add keys in Jarvis → More → Services on your phone (or the web).")
                        .font(.system(size: 12)).foregroundStyle(dim).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !folio.isEmpty { PortfolioCard(folio: folio) }
                ForEach(cards) { c in
                    ServiceCardView(card: c, expanded: open == c.id)
                        .onTapGesture { open = open == c.id ? nil : c.id }
                }
            }
        }
    }
}

private struct ServiceCardView: View {
    let card: MacServiceCard
    let expanded: Bool

    private var color: Color {
        switch card.tone {
        case .error: return Color(red: 1, green: 0.42, blue: 0.38)
        case .warning: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .ok: return Color(red: 0.2, green: 0.83, blue: 0.6)
        case .info: return JcAccent.color
        case .idle: return .white.opacity(0.35)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(card.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(card.headline).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer()
            }
            if let e = card.error {
                Text(e).font(.system(size: 11)).foregroundStyle(color)
            } else if !card.reason.isEmpty {
                Text(card.reason).font(.system(size: 11)).foregroundStyle(dim).lineLimit(expanded ? 3 : 1)
            }
            if expanded {
                ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let url = item.url {
                            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right") }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
    }
}

private struct PortfolioCard: View {
    let folio: MacPortfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bitcoinsign.circle").foregroundStyle(JcAccent.color)
                Text("Portfolio").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let total = folio.total {
                    Text(total).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
            if !folio.quotes.isEmpty {
                HStack(spacing: 10) {
                    ForEach(folio.quotes, id: \.symbol) { q in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(q.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(dim)
                            Text(q.change).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(q.up ? Color(red: 0.2, green: 0.83, blue: 0.6) : Color(red: 1, green: 0.42, blue: 0.38))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
    }
}

/// Talking to Jarvis in the notch: jc-client's voice panel (orb, transcript,
/// mute / start / send) in its island layout — one stage the island's width. It holds
/// the microphone while it's up, so "Hey Jarvis" steps aside; the island stays
/// open while it's showing (IslandPin).
struct VoicePane: View {
    let ui: IslandUI
    let make: (() -> NSViewController?)?
    /// Made once when the view appears (it starts a voice session), not per render.
    @State private var panel: NSViewController?
    @State private var tried = false

    var body: some View {
        // Always the panel's size, even before the panel exists: an empty view
        // never appears, and then the panel would never be made.
        ZStack {
            if let panel {
                VoicePanelHost(controller: panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else if tried {
                Text("The voice panel isn't available — is jc-client running?")
                    .font(.system(size: 12)).foregroundStyle(dim)
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandLayout.voicePanelHeight, maxHeight: IslandLayout.voicePanelHeight)
        .onAppear {
            if panel == nil { panel = make?() }
            tried = true
            NotificationCenter.default.post(name: .jarvisVoicePanelOpened, object: nil)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .jarvisVoicePanelClosed, object: nil)
        }
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

/// Apple Mail's inbox and a compose box.
struct MailPane: View {
    let ui: IslandUI
    @Bindable var mail = MailController.shared
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mail.mailRunning ? "\(mail.inbox.unread) unread" : "Mail isn't open")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button(composing ? "Inbox" : "Compose") { composing.toggle() }
                    .buttonStyle(IslandButtonStyle(tint: .white))
            }
            if composing { compose } else { list }
        }
        .onAppear { mail.setVisible(true) }
        .onDisappear { mail.setVisible(false); ui.pinned = false }
        .onChange(of: composing) { _, c in ui.pinned = c }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(mail.inbox.messages) { m in
                    HStack(spacing: 8) {
                        Circle().fill(m.isRead ? Color.clear : JcAccent.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.senderName).font(.system(size: 12, weight: m.isRead ? .regular : .semibold))
                                .foregroundStyle(.white).lineLimit(1)
                            Text(m.subject).font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
                        }
                        Spacer()
                        if !m.isRead {
                            Button { mail.markRead(m) } label: { Image(systemName: "envelope.open") }.help("Mark as read")
                        }
                        Button { mail.reply(m) } label: { Image(systemName: "arrowshape.turn.up.left") }.help("Reply in Mail")
                        Button { mail.open(m) } label: { Image(systemName: "arrow.up.right") }.help("Open in Mail")
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                }
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("To", text: $mail.to).textFieldStyle(.roundedBorder)
            TextField("Subject", text: $mail.subject).textFieldStyle(.roundedBorder)
            TextEditor(text: $mail.body).font(.system(size: 12)).frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            HStack {
                Picker("", selection: $mail.via) {
                    ForEach(MailController.Via.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                if let s = mail.status { Text(s).font(.system(size: 11)).foregroundStyle(dim).lineLimit(2) }
                Spacer()
                if mail.via == .appleMail {
                    Button("Open in Mail") { mail.openDraftInMail() }.buttonStyle(IslandButtonStyle(tint: .white))
                }
                Button(mail.sending ? "Sending…" : "Send") { mail.send() }
                    .buttonStyle(IslandButtonStyle(tint: JcAccent.color)).disabled(mail.sending)
            }
        }
    }
}
