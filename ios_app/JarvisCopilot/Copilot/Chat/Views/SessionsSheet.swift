import SwiftUI

/// The chat list, ported from `chat/widgets/sessions_drawer.dart`. Flutter uses a
/// side drawer; a sheet is the iOS idiom and reaches the thumb, so the same
/// content lands in one.
///
/// Pinned chats float to the top, then Today / Yesterday / Earlier
/// (``ChatSessionGroup``). Search filters as you type. Rename, pin and delete are
/// swipe actions — a phone-native replacement for Flutter's ⋯ popup — and also
/// live in a long-press menu so they are discoverable.
struct ChatSessionsSheet: View {
    let store: ChatStore

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: ChatSessionSummary?
    @State private var renameText = ""
    @State private var deleting: ChatSessionSummary?

    private var groups: [ChatSessionGroup] {
        ChatSessionGroup.group(store.sessions, query: query)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Chats")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.startNewSession()
                            dismiss()
                        } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search chats")
        }
        .presentationDetents([.large])
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Chat title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let session = renaming else { return }
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming = nil
                guard !title.isEmpty, title != session.title else { return }
                Task { await store.renameSession(session.id, title: title) }
            }
        }
        .alert("Delete chat", isPresented: Binding(get: { deleting != nil },
                                                   set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let session = deleting else { return }
                deleting = nil
                Task { await store.deleteSession(session.id) }
            }
        } message: {
            Text("Delete \"\(deleting?.displayTitle ?? "")\"? This cannot be undone.")
        }
    }

    @ViewBuilder private var content: some View {
        if store.sessionsLoading && store.sessions.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).jcScreen()
        } else if groups.isEmpty {
            CenteredMessage(text: query.isEmpty
                            ? "No chats yet.\nStart a conversation and it will show up here."
                            : "No chat title contains “\(query)”.")
                .frame(maxHeight: .infinity)
                .jcScreen()
        } else {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.loadSessions() }
            .jcScreen()
        }
    }

    private func row(_ session: ChatSessionSummary) -> some View {
        let active = session.id == store.sessionID
        return Button {
            dismiss()
            guard !active else { return }
            Task { await store.openSession(session.id) }
        } label: {
            HStack(spacing: 8) {
                if session.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(JcTheme.amber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 13.5, weight: active ? .bold : .medium))
                        .foregroundStyle(active ? JcTheme.accent : JcTheme.text)
                        .lineLimit(1)
                    if session.isStreaming {
                        Text("streaming…").font(.system(size: 11)).foregroundStyle(JcTheme.blue)
                    } else if let subtitle = subtitle(session) {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(active ? JcTheme.accent.opacity(0.12) : Color.clear)
        .listRowSeparatorTint(JcTheme.glassBorder)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await store.pinSession(session.id, pinned: !session.pinned) }
            } label: {
                Label(session.pinned ? "Unpin" : "Pin",
                      systemImage: session.pinned ? "pin.slash" : "pin")
            }
            .tint(JcTheme.amber)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = session } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: { Label("Rename", systemImage: "pencil") }
            .tint(JcTheme.primaryBlue)
        }
        .contextMenu {
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                Task { await store.pinSession(session.id, pinned: !session.pinned) }
            } label: {
                Label(session.pinned ? "Unpin" : "Pin",
                      systemImage: session.pinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) { deleting = session } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(_ session: ChatSessionSummary) -> String? {
        guard let stamp = session.updatedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(stamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
