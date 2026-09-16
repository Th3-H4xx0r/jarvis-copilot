import SwiftUI

/// A conversation with Jarvis: the transcript, the clarify bar, and the composer.
///
/// This is the chat, minus the Chat tab's chrome — no navigation stack, no
/// toolbar, no session list. Any screen that wants a conversation uses this one
/// rather than rebuilding it: markdown, tool cards, streaming, the scroll
/// behaviour, the link guard and the on-device retry all come with it.
///
/// Two things a host can change. `emptyState` is what fills the space before the
/// first message — the Chat tab puts its welcome and dashboard there; a screen
/// doing one job usually wants nothing. `footer` replaces the composer, for a
/// conversation that has finished and only needs a way out.
struct ChatConversationView<Empty: View, Footer: View>: View {
    let store: ChatStore
    var placeholder: String = "Message Jarvis"
    /// Built with the height it has to fill, because a welcome screen lays itself
    /// out differently on a short one.
    let emptyState: (CGFloat) -> Empty
    let footer: Footer

    /// Whether the composer is offered. A host that passes a footer may still want
    /// it — the footer is only a replacement while this is false, so a footer that
    /// renders conditionally does not silently take the keyboard away.
    private let showsComposer: Bool

    @State private var draft = ""
    /// Bumped on send so the multi-line field is recreated — clearing its binding
    /// while it is focused otherwise leaves the old text on screen.
    @State private var composerGeneration = 0
    @FocusState private var focused: Bool

    private static var bottomAnchor: String { "chat.bottom" }
    private static var welcomeAnchor: String { "chat.welcome" }

    init(store: ChatStore,
         placeholder: String = "Message Jarvis",
         showsComposer: Bool = true,
         @ViewBuilder emptyState: @escaping (CGFloat) -> Empty,
         @ViewBuilder footer: () -> Footer) {
        self.init(store: store, placeholder: placeholder, showsComposer: showsComposer,
                  emptyState: emptyState, footer: footer())
    }

    fileprivate init(store: ChatStore, placeholder: String, showsComposer: Bool,
                     emptyState: @escaping (CGFloat) -> Empty, footer: Footer) {
        self.store = store
        self.placeholder = placeholder
        self.showsComposer = showsComposer
        self.emptyState = emptyState
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error { banner(error) }
            transcript
            if let clarify = store.pendingClarify {
                ChatClarifyBar(prompt: clarify) { answer in
                    Task { await store.respondClarify(answer) }
                }
            }
            footer
            if showsComposer {
                ChatComposer(store: store, placeholder: placeholder, draft: $draft,
                             generation: composerGeneration, focused: $focused,
                             onSend: send, onStop: stop)
            }
        }
        // Markdown links in a reply are model output; anything that is not
        // http/https/mailto has to be confirmed (security M5).
        .chatLinkGuard()
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.historyLoading && store.messages.isEmpty {
                            ProgressView().padding(.vertical, 40).frame(maxWidth: .infinity)
                        } else if store.messages.isEmpty {
                            emptyState(geometry.size.height)
                                .frame(minHeight: max(0, geometry.size.height - 29))
                                .id(Self.welcomeAnchor)
                        }
                        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                            ChatMessageRow(
                                row: row,
                                isFirst: index == 0,
                                onCopy: { UIPasteboard.general.string = row.message.plainText },
                                onRetryOnServer: row.message.onDevice
                                    ? { Task { await store.retryOnServer(row.message) } } : nil,
                                // A submitted form becomes the user's next message,
                                // so the turn after it reads the answers normally.
                                onFormSubmit: { reply in Task { await store.send(reply) } })
                                .id(row.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    // Whatever holds the keyboard — the composer, or a box in a
                    // form card the agent drew.
                    focused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                .onAppear { jump(proxy) }
                // A tick, not the transcript: `onChange(of: store.messages)` compares
                // every message in the thread on every streamed token
                // (swift-correctness H9).
                .onChange(of: store.messagesTick) { _, _ in
                    guard !store.messages.isEmpty else { jump(proxy); return }
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                // Opening or switching a chat lands at the newest message, however
                // far up the previous thread was scrolled.
                .onChange(of: store.sessionID) { _, _ in
                    // The draft belonged to the chat that was open; starting or
                    // switching to another must not carry it across.
                    draft = ""
                    composerGeneration += 1
                    jump(proxy)
                }
                .onChange(of: store.historyLoading) { _, loading in if !loading { jump(proxy) } }
                .onChange(of: focused) { _, isFocused in
                    if isFocused, !store.messages.isEmpty {
                        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// A single scroll lands short: the thread keeps growing taller across frames
    /// as markdown, tool rows and images lay out. Re-pin on the next runloop turn.
    @MainActor private func jump(_ proxy: ScrollViewProxy) {
        let empty = store.messages.isEmpty
        proxy.scrollTo(empty ? Self.welcomeAnchor : Self.bottomAnchor,
                       anchor: empty ? .top : .bottom)
        Task { @MainActor in
            proxy.scrollTo(empty ? Self.welcomeAnchor : Self.bottomAnchor,
                           anchor: empty ? .top : .bottom)
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            JcIcon("exclamationmark.triangle.fill").foregroundStyle(JcTheme.danger)
            Text(text).font(.footnote).foregroundStyle(JcTheme.text)
            Spacer(minLength: 0)
            Button { store.error = nil } label: {
                JcIcon("xmark", size: 11, weight: .semibold)
                    .foregroundStyle(JcTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(JcTheme.danger.opacity(0.12))
    }

    // MARK: Sending

    private func send() {
        let text = draft
        // A typed reply while the agent's clarify question is open answers it, so
        // the usual "not while streaming" rule does not apply to that one case.
        let clarifying = store.pendingClarify != nil
        guard store.canSend(draft: text) ||
                (clarifying && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else { return }
        draft = ""
        composerGeneration += 1
        Task { await store.send(text) }
    }

    private func stop() { Task { await store.cancel() } }
}

/// The model this conversation runs on, and a tap to change it.
///
/// A toolbar item rather than part of the conversation, because where it belongs
/// depends on the screen — but the same capsule and the same picker sheet
/// everywhere, over the same `ChatStore`.
struct ChatModelButton: View {
    let store: ChatStore
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 6) {
                JcIcon("sparkles").foregroundStyle(JcTheme.accent)
                Text(ChatUIFormat.shortModelName(store.selectedModel?.label
                                                 ?? store.selectedModelID ?? ""))
                    .lineLimit(1)
            }
            .font(JcText.body)
            .frame(maxWidth: 112)
        }
        .buttonStyle(.plain)
        .foregroundStyle(JcTheme.text)
        .accessibilityLabel("Chat model")
        .sheet(isPresented: $picking) { ChatModelPickerSheet(store: store) }
        .task { if store.models == nil { await store.loadModels() } }
    }
}

extension ChatConversationView where Footer == EmptyView {
    /// A conversation with the ordinary composer.
    init(store: ChatStore, placeholder: String = "Message Jarvis",
         @ViewBuilder emptyState: @escaping (CGFloat) -> Empty) {
        self.init(store: store, placeholder: placeholder, showsComposer: true,
                  emptyState: emptyState, footer: EmptyView())
    }
}

extension ChatConversationView where Empty == EmptyView {
    /// A conversation with nothing in place of an empty transcript.
    init(store: ChatStore, placeholder: String = "Message Jarvis",
         showsComposer: Bool = true,
         @ViewBuilder footer: () -> Footer) {
        self.init(store: store, placeholder: placeholder, showsComposer: showsComposer,
                  emptyState: { _ in EmptyView() }, footer: footer())
    }
}

extension ChatConversationView where Empty == EmptyView, Footer == EmptyView {
    init(store: ChatStore, placeholder: String = "Message Jarvis") {
        self.init(store: store, placeholder: placeholder, showsComposer: true,
                  emptyState: { _ in EmptyView() }, footer: EmptyView())
    }
}
