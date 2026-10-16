import SwiftUI

/// One call: summary, key points, to-dos (tap to tick), the transcript, and
/// Share (Markdown), Summarize again and Delete.
struct NoteDetailScreen: View {
    let noteID: String
    var store: NotesStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var markdown: (text: String, filename: String)?

    private var note: AgentNote? { store.details[noteID] ?? store.notes.first { $0.id == noteID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let note {
                    header(note)
                    if let error = store.detailErrors[noteID], store.details[noteID] == nil {
                        Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
                    }
                    summaryCard(note)
                    if !note.keyPoints.isEmpty { keyPoints(note) }
                    if !note.todos.isEmpty { todos(note) }
                    transcript(note)
                } else if let error = store.detailErrors[noteID] {
                    Text(error).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
                } else {
                    ProgressView().tint(JcTheme.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .refreshable { await store.load(noteID) }
        .jcScreen(note?.title ?? "Note")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let markdown {
                    ShareLink(item: markdown.text, subject: Text(note?.title ?? "Call notes")) {
                        JcIcon("square.and.arrow.up", size: 17)
                    }
                    .accessibilityLabel("Share as Markdown")
                }
                Button(role: .destructive) { confirmDelete = true } label: { JcIcon("trash", size: 17) }
                    .accessibilityLabel("Delete")
            }
        }
        .confirmationDialog("Delete this note on the server?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await store.delete(noteID) { dismiss() } }
            }
        } message: {
            Text("The Mac keeps its own copy.")
        }
        .task {
            await store.load(noteID)
            markdown = await store.markdown(noteID)
        }
        .onChange(of: store.details[noteID]) { _, _ in
            Task { markdown = await store.markdown(noteID) }
        }
        .moreScreenVisibility { store.setVisible($0, owner: "note-\(noteID)") }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3)
    }

    private func header(_ note: AgentNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(JcText.title)
                .foregroundStyle(JcTheme.text)
            Text([note.start.formatted(date: .complete, time: .shortened), "\(note.minutes) min", note.app]
                .compactMap { $0 }.joined(separator: " · "))
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
            if !note.speakers.isEmpty {
                Text(note.speakers.map(\.name).joined(separator: ", "))
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func summaryCard(_ note: AgentNote) -> some View {
        card("Summary") {
            if let summary = note.summary {
                Text(summary).font(JcText.body).foregroundStyle(JcTheme.text).textSelection(.enabled)
            } else {
                switch note.summaryStatus {
                case .pending:
                    HStack(spacing: 8) {
                        ProgressView().tint(JcTheme.accent)
                        Text("Jarvis is writing the summary…").foregroundStyle(JcTheme.muted)
                    }
                case .failed:
                    Text("The summary failed: \(note.summaryError ?? "no model answered").")
                        .foregroundStyle(JcTheme.amber)
                case .none, .done:
                    Text("No summary yet.").foregroundStyle(JcTheme.muted)
                }
            }
            if note.summaryStatus != .pending && note.lineCount > 0 && (note.summary == nil || note.summaryStatus == .failed) {
                Button("Summarize") { Task { await store.summarize(noteID) } }
                    .buttonStyle(.jcGlass(compact: true))
            }
        }
    }

    private func keyPoints(_ note: AgentNote) -> some View {
        card("Key points") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(note.keyPoints, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(JcTheme.accent).frame(width: 5, height: 5)
                        Text(point).font(JcText.body).foregroundStyle(JcTheme.text)
                    }
                }
            }
        }
    }

    private func todos(_ note: AgentNote) -> some View {
        card("To-dos") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(note.todos) { todo in
                    Button {
                        Task { await store.toggleTodo(noteID, index: todo.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            JcIcon(todo.done ? "checkmark.circle.fill" : "circle", size: 18)
                                .foregroundStyle(todo.done ? JcTheme.accent : JcTheme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(todo.text)
                                    .font(JcText.body)
                                    .foregroundStyle(todo.done ? JcTheme.muted : JcTheme.text)
                                    .strikethrough(todo.done)
                                let extra = [todo.owner, todo.due].compactMap { $0 }
                                if !extra.isEmpty {
                                    Text(extra.joined(separator: " · ")).font(JcText.small).foregroundStyle(JcTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.details[noteID] == nil)
                    .accessibilityLabel("\(todo.text), \(todo.done ? "done" : "not done")")
                }
            }
        }
    }

    private func transcript(_ note: AgentNote) -> some View {
        card("Transcript") {
            if note.lines.isEmpty {
                Text(store.details[noteID] == nil ? "Loading…" : "No transcript.").foregroundStyle(JcTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(note.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(note.name(of: line.speaker))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(note.isMe(line.speaker) ? JcTheme.accent : JcTheme.text)
                                Text(AgentNote.clock(line.start))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(JcTheme.muted)
                            }
                            Text(line.text)
                                .font(.system(size: 14))
                                .foregroundStyle(JcTheme.text.opacity(0.9))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(JcText.label)
                .foregroundStyle(JcTheme.muted)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }
}
