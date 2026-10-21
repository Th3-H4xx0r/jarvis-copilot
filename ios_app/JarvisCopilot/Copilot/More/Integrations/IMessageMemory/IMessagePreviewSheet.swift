import SwiftUI

/// A chat's latest messages, asked of the Mac live (nothing is kept on the
/// server), so he can see what a chat is before ticking it. The tick is here too,
/// and a Memories tab with what Jarvis already remembers from it.
struct IMessagePreviewSheet: View {
    let chat: IMessageChat
    let store: IMessageMemoryStore

    enum Tab: String, CaseIterable, Identifiable {
        case messages = "Messages"
        case memories = "Memories"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .messages
    @State private var messages: [IMessagePreviewMessage]?
    @State private var error: String?
    /// Bumped by Retry, which re-runs the load task.
    @State private var attempt = 0
    @State private var memories: IMessageChatMemoriesStore

    init(chat: IMessageChat, store: IMessageMemoryStore) {
        self.chat = chat
        self.store = store
        _memories = State(initialValue: IMessageChatMemoriesStore(guid: chat.guid))
    }

    /// The chat as the store has it now, so the tick follows the server's answer.
    private var live: IMessageChat { store.card?.chats.first { $0.guid == chat.guid } ?? chat }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .messages: content
                case .memories: IMessageChatMemoriesView(store: memories)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    tickHeader
                    tabPicker
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .jcScreen()
            .moreToast($memories.toast)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(live.displayName)
                            .font(.headline)
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if live.isGroup { StatusPill("Group", color: JcTheme.accent, dense: true) }
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: attempt) { await load() }
    }

    // MARK: Pieces

    private var tickHeader: some View {
        HStack(spacing: 12) {
            Text("Remember this chat")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { live.effective },
                                     set: { on in Task { await store.setTicked(live, on) } }))
                .labelsHidden()
                .tint(JcTheme.accent)
                .accessibilityLabel("Remember \(live.displayName)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var tabPicker: some View {
        Picker("Show", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var content: some View {
        if let messages {
            if messages.isEmpty {
                CenteredMessage(text: "No messages in this chat yet.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            IMessagePreviewBubble(message: message,
                                                  showsSender: live.isGroup && !message.isFromMe
                                                      && (index == 0 || messages[index - 1].sender != message.sender
                                                          || messages[index - 1].isFromMe))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
            }
        } else if let error {
            CenteredMessage(text: error, color: JcTheme.danger) { attempt += 1 }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking your Mac…")
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }

    private func load() async {
        messages = nil
        error = nil
        do {
            messages = try await store.preview(chat)
        } catch {
            if !wasCancelled(error) { self.error = apiErrorMessage(error) }
        }
    }
}

/// One message: his on the right in the accent tint, theirs on the left on glass,
/// with who sent it above theirs in a group.
private struct IMessagePreviewBubble: View {
    let message: IMessagePreviewMessage
    let showsSender: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
            if showsSender && !message.sender.isEmpty {
                Text(message.sender)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 6)
            }
            Text(message.text)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.isFromMe ? JcTheme.accent.opacity(0.28) : JcTheme.glassFill, in: shape)
                .overlay(shape.strokeBorder(message.isFromMe ? JcTheme.accent.opacity(0.4) : JcTheme.glassBorder,
                                            lineWidth: 1))
            Text(message.timeLabel())
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: 300, alignment: message.isFromMe ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}
