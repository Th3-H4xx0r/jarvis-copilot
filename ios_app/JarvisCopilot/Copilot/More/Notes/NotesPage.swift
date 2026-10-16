import SwiftUI

/// Where the Notes screens push, inside More's stack.
enum NotesRoute: Hashable {
    case detail(String)
}

/// More → Notes: the calls the Jarvis Mac app recorded, newest first, each with
/// its summary and to-dos. Live while on screen from the `notes` topic.
struct NotesPage: View {
    var store: NotesStore = .shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let error = store.loadError, store.notes.isEmpty {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
                ForEach(store.notes) { note in
                    NavigationLink(value: NotesRoute.detail(note.id)) {
                        NoteCard(note: note)
                    }
                    .buttonStyle(.plain)
                }
                if store.loaded && store.notes.isEmpty && store.loadError == nil {
                    emptyState
                }
                if !store.loaded {
                    ProgressView().tint(JcTheme.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .refreshable { await store.refresh() }
        .jcScreen("Notes")
        .navigationDestination(for: NotesRoute.self) { route in
            switch route {
            case .detail(let id): NoteDetailScreen(noteID: id, store: store)
            }
        }
        .moreScreenVisibility { store.setVisible($0, owner: "notes-page") }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No call notes yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text("Record a call from the Jarvis Mac app (menu bar → Record a call). Your microphone is “You”, the call is “Them”; when you stop, the transcript, a summary and the to-dos show up here.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }
}

/// One call on the list: title, when and how long, the summary's first lines.
struct NoteCard: View {
    let note: AgentNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                JcIcon("chevron.right", size: 12).foregroundStyle(JcTheme.muted)
            }
            Text(meta)
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
            if let summary = note.summary {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.text.opacity(0.8))
                    .lineLimit(3)
            } else {
                Text(statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(note.summaryStatus == .failed ? JcTheme.amber : JcTheme.muted)
            }
            if !note.todos.isEmpty {
                let open = note.todos.filter { !$0.done }.count
                HStack(spacing: 6) {
                    JcIcon("checklist", size: 12)
                    Text(open == 0 ? "All to-dos done" : "\(open) to-do\(open == 1 ? "" : "s")")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(JcTheme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        [note.start.formatted(date: .abbreviated, time: .shortened), "\(note.minutes) min", note.app]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var statusLine: String {
        switch note.summaryStatus {
        case .pending: return "Jarvis is writing the summary…"
        case .failed: return "The summary failed."
        case .none, .done: return note.lineCount == 0 ? "No transcript." : "\(note.lineCount) lines of transcript"
        }
    }
}
