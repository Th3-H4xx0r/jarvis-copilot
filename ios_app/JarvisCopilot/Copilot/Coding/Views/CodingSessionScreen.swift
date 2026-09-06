import SwiftUI

/// One open coding session: its Claude Code transcript, the composer that types
/// into the live TUI, and the live terminal panel. Port of `coding/coding_chat.dart`
/// plus the detail half of `pages/coding_page.dart`.
///
/// The terminal PTY **is** the input channel in both modes — flipping between
/// Chat and Terminal only swaps what is RENDERED, exactly as the Flutter build
/// did; the attach survives the toggle. Deviation: Chat is the default view
/// (Flutter defaulted to Terminal) because the transcript is the readable
/// surface on a phone and the terminal is one tap away.
struct CodingSessionScreen: View {
    let coding: CodingStore
    let session: CodingSessionStore

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var chatMode = true
    @State private var settingsOpen = false
    @State private var confirmingDelete = false
    @State private var promptSheet: CodingPromptState?

    private var detail: CodingSession? { coding.selected }
    private var live: Bool { detail?.isLive ?? false }
    private var ended: Bool { detail?.isEnded ?? false }

    var body: some View {
        VStack(spacing: 0) {
            // Approvals ride above the session too — Flutter kept the banner
            // pinned over the whole Coding tab, list or detail.
            CodingApprovalBanner(store: coding)
            subheader
            CodingModeToggle(chat: $chatMode)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if chatMode {
                chat
            } else {
                terminal
            }
        }
        .jcScreen(detail?.displayTitle ?? "Session")
        // Tool cards and the terminal render server text too — the whole screen
        // gets the transcript's link policy, not just the chat bubbles.
        .codingSafeLinks()
        .toolbar { toolbar }
        .sheet(isPresented: $settingsOpen) {
            if let detail {
                CodingSessionSettingsSheet(store: coding, session: detail)
            }
        }
        .sheet(item: $promptSheet) { prompt in
            CodingPromptSheet(prompt: prompt,
                              sendKey: { await session.sendRaw($0) },
                              sendText: { await session.sendText($0) })
                .onDisappear { Task { await session.promptSheetClosed(prompt) } }
        }
        .confirmationDialog("Delete session", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await coding.delete() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the session and permanently removes it.")
        }
        .onAppear {
            session.start()
            Task { await coding.loadDevices() }
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            // The poll loop stops itself while backgrounded; this is the only
            // path that revives it, so it must be unconditional.
            if phase == .active { Task { await session.resume() } }
        }
        .onChange(of: session.shouldPresentPrompt) { _, present in
            guard present, let p = session.prompt else { return }
            session.promptOpen = true
            promptSheet = p
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !ended {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { live ? await coding.stop() : await coding.restart() }
                } label: {
                    Image(systemName: live ? "stop.fill" : "arrow.clockwise.circle")
                        .font(.system(size: 16))
                }
                .tint(live ? JcTheme.danger : JcTheme.primaryBlue)
                .disabled(coding.busy)
                .accessibilityLabel(live ? "Stop session" : "Restart session")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 15))
                }
                .tint(JcTheme.text)
                .disabled(coding.busy)
                .accessibilityLabel("Delete session")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { settingsOpen = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16))
            }
            .tint(JcTheme.text)
            .disabled(detail == nil)
            .accessibilityLabel("Session settings")
        }
    }

    private var subheader: some View {
        HStack(spacing: 8) {
            if let cwd = detail?.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            CodingStatusPill(status: detail?.status ?? "starting")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            if ended {
                CodingEndedChatBanner { chatMode = false }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            CodingChatTranscript(session: session,
                                 live: isLive,
                                 onOpenPrompt: { await openPromptFromBanner() })
            CodingChatComposer(session: session, enabled: isLive)
        }
    }

    /// Prefer the freshest signal (the `/messages` status), falling back to the
    /// polled session detail.
    private var isLive: Bool { session.transcript.isLive ?? live }

    private func openPromptFromBanner() async {
        guard let p = await session.promptForBanner() else { return }
        session.promptOpen = true
        promptSheet = p
    }

    // MARK: Terminal

    private var terminal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = coding.error { CodingInlineError(message: error) }
                if let sync = coding.sync, sync.enabled {
                    CodingSyncCard(sync: sync) { await coding.refreshSync() }
                }
                if let detail, ended {
                    CodingEndedPanel(
                        session: detail,
                        busy: coding.busy,
                        onRelaunchDevice: { Task { await coding.relaunchOnDevice() } },
                        onResumeServer: {
                            Task {
                                if let id = await coding.resumeSession(detail.id) {
                                    await coding.select(id)
                                }
                            }
                        },
                        onReopenTerminal: { Task { await coding.reopenTerminal() } },
                        onRestart: { Task { await coding.restart() } },
                        onDelete: { confirmingDelete = true })
                } else {
                    CodingTerminalPanel(session: session,
                                        host: detail?.host ?? "server")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        // The key bar + input stay PINNED below the scrolling body so they're
        // reachable with the keyboard up — the key bar is what drives the
        // interactive TUI prompts a soft keyboard can't.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !ended {
                VStack(spacing: 0) {
                    CodingTerminalKeyBar { key in Task { await session.sendRaw(key) } }
                    CodingTerminalInputRow(session: session, enabled: live)
                }
                .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Small chrome

/// The lifecycle pill in the session header (starting / running / idle / …).
struct CodingStatusPill: View {
    let status: String

    var body: some View {
        let c = CodingUI.statusColor(status)
        Text(status)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(c.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(c.opacity(0.30), lineWidth: 1))
    }
}

/// The slim segmented control between the live terminal and the transcript.
/// Purely a view switch — the PTY/SSE stay attached either way.
struct CodingModeToggle: View {
    @Binding var chat: Bool

    var body: some View {
        HStack(spacing: 3) {
            segment(selected: !chat, symbol: "terminal", label: "Terminal") { chat = false }
            segment(selected: chat, symbol: "bubble.left", label: "Chat") { chat = true }
        }
        .padding(3)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }

    private func segment(selected: Bool, symbol: String, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? JcTheme.primaryBlue.opacity(0.20) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? JcTheme.primaryBlue.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// `CodingPromptState` isn't `Identifiable` (it's a value the API decodes), so
/// the sheet keys on its signature — the same identity the store uses to decide
/// whether a prompt is "the same one" the user already dismissed.
extension CodingPromptState: Identifiable {
    var id: String { signature }
}
