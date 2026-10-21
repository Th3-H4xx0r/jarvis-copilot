import SwiftUI

/// The preview sheet's Memories tab: the facts saved from this chat, the cards still
/// waiting for Store / Skip, and the conversations remembered whole. Facts and
/// conversations swipe to delete.
struct IMessageChatMemoriesView: View {
    let store: IMessageChatMemoriesStore

    /// Conversations opened to their full transcript.
    @State private var expanded: Set<String> = []

    var body: some View {
        ZStack {
            if let memories = store.memories {
                list(memories)
            } else if let error = store.errorMessage {
                CenteredMessage(text: error, color: JcTheme.danger) { Task { await store.load() } }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Loads the first time the tab shows. A load cut short by switching tabs
        // left nothing behind, so it simply asks again.
        .task { if store.memories == nil && store.errorMessage == nil { await store.load() } }
    }

    // MARK: The list

    private func list(_ memories: IMessageChatMemories) -> some View {
        List {
            if memories.isEmpty {
                Text("Nothing remembered from this chat yet.")
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !memories.facts.isEmpty {
                Section {
                    ForEach(memories.facts) { factRow($0) }
                } header: {
                    header("Facts")
                }
            }
            if !memories.waiting.isEmpty {
                Section {
                    ForEach(memories.waiting) { fact in
                        IMessageFactCard(fact: fact) { keep in
                            Task { await store.decide(fact, store: keep) }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    header("Waiting for you")
                }
            }
            if !memories.conversations.isEmpty {
                Section {
                    ForEach(memories.conversations) { conversationRow($0) }
                } header: {
                    header("Conversations")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
        .animation(.snappy, value: memories)
    }

    private func header(_ title: String) -> some View {
        SectionHeader(title)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    // MARK: Rows

    private func factRow(_ entry: IMessageMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let when = when(entry) {
                Text(when)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .memoryRow { Task { await store.delete(entry, .fact) } }
    }

    private func conversationRow(_ entry: IMessageMemoryEntry) -> some View {
        let open = expanded.contains(entry.id)
        return Button {
            withAnimation(.snappy) {
                if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title.isEmpty ? "Conversation" : entry.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(open ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if !entry.body.isEmpty {
                        JcIcon(open ? "chevron.up" : "chevron.down", size: 11)
                            .foregroundStyle(JcTheme.muted)
                    }
                }
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.system(size: 13.5))
                        .foregroundStyle(open ? JcTheme.text : JcTheme.muted)
                        .lineLimit(open ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let when = when(entry) {
                    Text(when)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.body.isEmpty ? "" : (open ? "Shows less" : "Shows the whole conversation"))
        .memoryRow { Task { await store.delete(entry, .conversation) } }
    }

    /// "5 minutes ago", or nil when the server gave no time.
    private func when(_ entry: IMessageMemoryEntry) -> String? {
        entry.at > 0 ? IMessageFact.relative(entry.date) : nil
    }
}

private extension View {
    /// A frosted row that swipes to Delete. The row leaves the list at once (the
    /// store removes it before asking the server), so `.destructive`'s slide-out
    /// animation matches what happens.
    func memoryRow(onDelete: @escaping () -> Void) -> some View {
        listRowBackground(JcTheme.glassFill)
            .listRowSeparatorTint(JcTheme.glassBorder)
            // SF Symbol, not JcIcon: swipe actions only render a `Label` with a system image.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash.fill")
                }
            }
    }
}
