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
            HStack(spacing: 8) {
                Picker("", selection: $chat.provider) {
                    ForEach(MacChatStore.Provider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 230).labelsHidden()
                if chat.provider != .jarvis {
                    if chat.localModels.isEmpty {
                        Text(chat.localError ?? "Looking for models…").font(.system(size: 11)).foregroundStyle(dim)
                    } else {
                        Picker("", selection: $chat.localModel) {
                            ForEach(chat.localModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 160)
                    }
                }
                Spacer()
                Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75)).help("New chat")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        if chat.lines.isEmpty {
                            Text("Ask Jarvis anything. Drop files here, or press ⌃⌥W to add the window you're in.")
                                .font(.system(size: 12)).foregroundStyle(dim)
                        }
                        ForEach(chat.lines) { line in ChatBubble(line: line).id(line.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.lines.last?.text) { _, _ in
                    if let id = chat.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
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
                }
            }
            HStack(spacing: 8) {
                TextField("Message Jarvis", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08)))
                    .onSubmit { chat.send() }
                Button { chat.busy ? chat.stop() : chat.send() } label: {
                    Image(systemName: chat.busy ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(JcAccent.deep))
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .disabled(!chat.busy && chat.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true; if chat.provider != .jarvis { chat.loadLocalModels() } }
        .onChange(of: chat.draft) { _, d in ui.pinned = !d.isEmpty || chat.busy }
        .onChange(of: chat.busy) { _, b in ui.pinned = b || !chat.draft.isEmpty }
        .onDisappear { ui.pinned = false }
    }
}

private struct ChatBubble: View {
    let line: MacChatStore.Line

    var body: some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(line.text).font(.system(size: 13)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14).fill(JcAccent.deep.opacity(0.85)))
            }
        case .assistant:
            Group {
                if line.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Self.markdown(line.text)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
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

/// What Apple Music or Spotify is playing, with the controls.
struct MusicPane: View {
    @Bindable var music = MusicController.shared
    @State private var scrub: Double?

    var body: some View {
        if let now = music.now {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(alignment: .top, spacing: 14) {
                    AsyncImage(url: now.artworkURL) { img in img.resizable().scaledToFill() } placeholder: {
                        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
                            .overlay(Image(systemName: "music.note").foregroundStyle(dim))
                    }
                    .frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(now.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text([now.artist, now.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 12)).foregroundStyle(dim).lineLimit(1)
                        Slider(value: Binding(get: { scrub ?? now.position(at: ctx.date) },
                                              set: { scrub = $0 }),
                               in: 0...max(1, now.duration)) { editing in
                            if !editing, let s = scrub { music.send(.seek(s)); scrub = nil }
                        }
                        .controlSize(.mini).tint(JcAccent.color)
                        HStack {
                            Text(NowPlaying.clock(scrub ?? now.position(at: ctx.date)))
                            Spacer()
                            Text(NowPlaying.clock(now.duration))
                        }
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(dim)
                        HStack(spacing: 22) {
                            Button { music.send(.previous) } label: { Image(systemName: "backward.fill") }
                            Button { music.send(.playPause) } label: {
                                Image(systemName: now.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                            }
                            Button { music.send(.next) } label: { Image(systemName: "forward.fill") }
                            Button { music.send(.shuffle(!music.shuffle)) } label: { Image(systemName: "shuffle") }
                                .foregroundStyle(music.shuffle ? JcAccent.color : .white.opacity(0.6)).help("Shuffle")
                            Button { music.send(.repeating(!music.repeating)) } label: { Image(systemName: "repeat") }
                                .foregroundStyle(music.repeating ? JcAccent.color : .white.opacity(0.6)).help("Repeat")
                            Image(systemName: "speaker.wave.2").foregroundStyle(dim)
                            Slider(value: $music.volume, in: 0...100).controlSize(.mini).frame(width: 70)
                            Spacer()
                            Text(now.player == .music ? "Music" : "Spotify").font(.system(size: 10)).foregroundStyle(dim)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                    }
                }
            }
        } else {
            Text("Nothing playing in Music or Spotify.").font(.system(size: 12)).foregroundStyle(dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
