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
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.startNewSession()
                            dismiss()
                        } label: { JcIcon("square.and.pencil").foregroundStyle(JcTheme.accent) }
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
                    JcIcon("pin.fill", size: 10).foregroundStyle(JcTheme.amber)
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
        // A swipe action's label must be `Label(_:systemImage:)`.
        //
        // SwiftUI bridges these to `UIContextualAction`, and to do that it has
        // to recognise the title and the image in the label. Our `jcIcon:`
        // initialiser builds a Phosphor `Image` in a fixed frame, which it
        // cannot, so it hosted the whole label instead: the icon filled the
        // action as a coloured blob and the words landed outside it, below the
        // button. Hence SF Symbols HERE specifically — the long-press menu
        // below renders in SwiftUI and keeps the app's own icons.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await store.pinSession(session.id, pinned: !session.pinned) }
            } label: {
                Label(session.pinned ? "Unpin" : "Pin",
                      systemImage: session.pinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(JcTheme.amber)
        }
        .swipeActions(edge: .trailing) {
            // NOT `role: .destructive`, deliberately. That role makes UIKit
            // play its row-DELETE animation the moment the button is tapped —
            // so the chat slid out of the list while the confirmation was still
            // on screen, and Cancel had nothing to put back (the data source
            // never changed, so the row only returned on a reload). The row now
            // stays exactly where it is, and the ONE place a chat is deleted is
            // the alert's confirm action.
            //
            // It still reads as a delete: `danger`, a trash glyph and the word.
            // The accent is not used here — it means "you can tap this"
            // everywhere else, and a delete has to look like a delete.
            Button {
                deleting = session
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .tint(JcTheme.danger)
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: { Label("Rename", systemImage: "pencil") }
            // Quiet: renaming is housekeeping, not an action worth a colour.
            .tint(JcTheme.muted)
        }
        .contextMenu {
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: { Label("Rename", jcIcon: "pencil") }
            Button {
                Task { await store.pinSession(session.id, pinned: !session.pinned) }
            } label: {
                Label(session.pinned ? "Unpin" : "Pin",
                      jcIcon: session.pinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) { deleting = session } label: {
                Label("Delete", jcIcon: "trash")
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
