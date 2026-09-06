import SwiftUI

/// The native Chat tab, sharing Voice's quiet canvas and glass controls.
///
/// All state and networking live in ``ChatStore``; this file is layout, chrome
/// and the three lifecycle hooks the Flutter page has:
///   * open the newest session on first appearance,
///   * poll the sessions LIST only while the tab is visible (every tab stays
///     alive in the shell, so `onAppear` is not a visibility signal), and
///   * re-read the list and the open thread whenever the tab or the app regains
///     focus, so a turn added by the voice screen shows up.
struct ChatPage: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: ChatStore
    @State private var draft = ""
    /// Bumped on send so the multi-line field is recreated — clearing its binding
    /// while it is focused otherwise leaves the old text on screen.
    @State private var composerGeneration = 0
    @State private var showSessions = false
    @State private var showModels = false
    @FocusState private var focused: Bool

    private static let bottomAnchor = "chat.bottom"
    private static let welcomeAnchor = "chat.welcome"

    /// `store` is injected by tests; the app takes the default. Built here rather
    /// than in `body` so the store outlives a re-render, and with
    /// `assumeIsolated` because `ChatStore` is `@MainActor` while a `View.init`
    /// is not (see the wave-1 notes in `docs/port/CONVENTIONS.md`).
    ///
    /// `onDevice:` is what makes the local-first lane real on this screen — with
    /// it nil every turn goes to the server, which is not what the on-device AI
    /// settings promise.
    init(store: ChatStore? = nil,
         launch: ChatLaunchBus? = nil,
         targets: DeepLinkTargets? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            ChatStore.production()
        })
        self.launch = launch ?? MainActor.assumeIsolated { ChatLaunchBus.shared }
        self.targets = targets ?? MainActor.assumeIsolated { DeepLinkTargets.shared }
    }

    /// "Ask JARVIS" from Siri / Shortcuts, and `jarviscopilot://chat?session=`.
    private let launch: ChatLaunchBus
    private let targets: DeepLinkTargets

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.error { banner(error) }
                transcript
                if let clarify = store.pendingClarify {
                    ChatClarifyBar(prompt: clarify) { answer in
                        Task { await store.respondClarify(answer) }
                    }
                }
                ChatComposer(store: store, draft: $draft, generation: composerGeneration,
                             focused: $focused, onSend: send, onStop: stop)
            }
            .jcScreen()
            // Markdown links in a reply are model output; anything that is not
            // http/https/mailto has to be confirmed (security M5).
            .chatLinkGuard()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Transparent chrome so the aurora runs behind the bar, as the
            // Flutter page does with `extendBodyBehindAppBar`.
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar { toolbar }
        }
        .task {
            await store.openInitial()
            // Take over "Ask JARVIS" from the `AppServices` fallback, which sends
            // through a private store — the answer is persisted but appears
            // nowhere the user can see it.
            await store.adoptChatLaunch(launch)
            await store.loadModels()
        }
        // A `jarviscopilot://chat?session=<id>` link, latched until this page
        // exists to consume it (on a cold launch the URL beats the shell).
        .onChange(of: targets.generation, initial: true) { _, _ in
            Task { await store.openDeepLinkTarget(targets) }
        }
        .onChange(of: router.selectedTab, initial: true) { _, tab in
            let visible = tab == .chat
            store.setListPolling(visible)
            if visible { Task { await store.refreshOnFocus() } }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, router.selectedTab == .chat else { return }
            Task { await store.refreshOnFocus() }
        }
        .sheet(isPresented: $showSessions) { ChatSessionsSheet(store: store) }
        .sheet(isPresented: $showModels) { ChatModelPickerSheet(store: store) }
    }

    // MARK: Chrome

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSessions = true } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel("Chats")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text("Chat").font(.headline)
                if !store.messages.isEmpty, !store.sessionTitle.isEmpty {
                    Text(store.sessionTitle)
                        .font(.caption2)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: 120)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) { modelCapsule }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                draft = ""
                composerGeneration += 1
                store.startNewSession()
            } label: { Image(systemName: "square.and.pencil") }
            .accessibilityLabel("New chat")
        }
    }

    private var modelCapsule: some View {
        Button { showModels = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(ChatUIFormat.shortModelName(store.selectedModel?.label ?? store.selectedModelID ?? ""))
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: 112)
        }
        .buttonStyle(.plain)
        .foregroundStyle(JcTheme.text)
        .accessibilityLabel("Chat model")
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JcTheme.danger)
            Text(text).font(.footnote).foregroundStyle(JcTheme.text)
            Spacer(minLength: 0)
            Button { store.error = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(JcTheme.danger.opacity(0.12))
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
                            ChatEmptyState(compact: geometry.size.height < 520) { suggestion in
                                focused = false
                                Task { await store.send(suggestion) }
                            }
                            .frame(minHeight: max(0, geometry.size.height - 29))
                            .id(Self.welcomeAnchor)
                        }
                        ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                            ChatMessageRow(
                                row: row,
                                isFirst: index == 0,
                                onCopy: { store.copy(row.message) },
                                onRetryOnServer: row.message.onDevice
                                    ? { Task { await store.retryOnServer(row.message) } } : nil)
                                .id(row.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { focused = false }
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
                .onChange(of: store.sessionID) { _, _ in jump(proxy) }
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
    /// as markdown, tool rows and images lay out. Re-pin on the next runloop turn,
    /// which is what the Flutter page's `_pinToBottom` retry loop is for.
    @MainActor private func jump(_ proxy: ScrollViewProxy) {
        let empty = store.messages.isEmpty
        proxy.scrollTo(empty ? Self.welcomeAnchor : Self.bottomAnchor, anchor: empty ? .top : .bottom)
        // Structured rather than `DispatchQueue.main.async`, so the hop stays on
        // the actor SwiftUI actually runs on (swift-correctness M31).
        Task { @MainActor in
            let empty = store.messages.isEmpty
            proxy.scrollTo(empty ? Self.welcomeAnchor : Self.bottomAnchor, anchor: empty ? .top : .bottom)
        }
    }

    // MARK: Actions

    private func send() {
        let text = draft
        let clarifying = store.pendingClarify != nil
        guard store.canSend(draft: text) ||
                (clarifying && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else { return }
        draft = ""
        composerGeneration += 1
        Task { await store.send(text) }
    }

    private func stop() {
        Task { await store.cancel() }
    }
}

/// A spacious welcome that gives way to the conversation after the first turn.
struct ChatEmptyState: View {
    var compact = false
    let onSuggestion: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tight: Bool { compact && !dynamicTypeSize.isAccessibilitySize }

    private static let suggestions = [
        ("sparkles", "Explore", "What can you do?"),
        ("sun.horizon", "Reflect", "Summarize my day"),
        ("desktopcomputer", "Connect", "Check my devices"),
        ("bolt", "Take action", "Run a skill"),
    ]

    var body: some View {
        VStack(spacing: tight ? 20 : 30) {
            VStack(spacing: tight ? 12 : 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: tight ? 24 : 28, weight: .light))
                    .foregroundStyle(JcTheme.cyan)
                    .frame(width: tight ? 52 : 72, height: tight ? 52 : 72)
                    .background {
                        Circle().fill(JcTheme.cyan.opacity(0.055))
                            .overlay(Circle().strokeBorder(JcTheme.cyan.opacity(0.14), lineWidth: 0.5))
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("What’s on your mind?")
                        .font(.system(.title2, weight: .medium))
                        .tracking(-0.6)
                        .foregroundStyle(JcTheme.text)
                    Text("A question, a plan, or the next thing to get done.")
                        .font(.subheadline)
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: 280)
                }
                .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                ForEach(Self.suggestions, id: \.2) { symbol, title, suggestion in
                    Button { onSuggestion(suggestion) } label: {
                        VStack(alignment: .leading, spacing: tight ? 8 : 12) {
                            HStack(spacing: 6) {
                                Image(systemName: symbol).foregroundStyle(JcTheme.cyan.opacity(0.85))
                                Text(title).foregroundStyle(JcTheme.muted)
                            }
                            .font(.caption)
                            Text(suggestion)
                                .font((tight ? Font.footnote : Font.subheadline).weight(.medium))
                                .foregroundStyle(JcTheme.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: tight ? 50 : 66, alignment: .leading)
                        .padding(tight ? 12 : 15)
                        .background(.white.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.065), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion)
                }
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 24)
        .padding(.vertical, tight ? 16 : 24)
        .frame(maxWidth: .infinity)
    }
}

/// The agent's open clarify question, above the composer: the question plus
/// tappable choices. Answering resumes the blocked turn instead of leaving it
/// stuck on "thinking" — typing an answer into the composer works too.
struct ChatClarifyBar: View {
    let prompt: ClarifyPrompt
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle").font(.system(size: 12))
                Text("Quick question").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(JcTheme.cyan)

            Text(prompt.question).font(.system(size: 14)).foregroundStyle(JcTheme.text)

            if !prompt.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(prompt.choices, id: \.self) { choice in
                            Button { onAnswer(choice) } label: {
                                Text(choice)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(JcTheme.text)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(JcTheme.cyan.opacity(0.18), in: Capsule())
                                    .overlay(Capsule().strokeBorder(JcTheme.cyan.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.cyan.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.cyan.opacity(0.30), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
