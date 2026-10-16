import AppKit
import SwiftUI

/// The Flow window's Notes page: Record / Stop, the notes on this Mac, and one
/// note's summary, to-dos and transcript.
struct NotesPage: View {
    private var taker: NoteTaker { NoteTaker.shared }
    @State private var selected: UUID?

    var body: some View {
        // Two plain columns — not an HSplitView: a split view nested in the
        // Flow window's own asked for the note's unwrapped width, so the
        // window's content grew past the window and was cut off at both sides.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RecordBar()
                    .padding(12)
                Divider()
                if taker.notes.isEmpty {
                    Spacer()
                    Text("Press Record when a call starts.\nTell the other people it's being recorded.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    List(taker.notes, selection: $selected) { note in
                        NoteRow(note: note, syncing: taker.syncing.contains(note.id)).tag(note.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(width: 270)
            Divider()
            Group {
                if let id = selected ?? taker.recordingID ?? taker.notes.first?.id, let note = taker.note(id) {
                    NoteDetail(note: note, live: note.id == taker.recordingID, syncing: taker.syncing.contains(note.id))
                        .id(note.id)
                } else {
                    Text("No note selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Notes")
        .onAppear { taker.sync() }
        .onChange(of: taker.recordingID) { _, id in if let id { selected = id } }
    }
}

private struct RecordBar: View {
    private var taker: NoteTaker { NoteTaker.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                taker.toggle()
            } label: {
                HStack {
                    Image(systemName: taker.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(taker.isRecording ? "Stop" : (taker.starting ? "Starting…" : "Record a call"))
                    Spacer()
                    if let start = taker.recording?.start {
                        Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(taker.isRecording ? .red : JcAccent.color)
            .disabled(taker.starting)
            if taker.isRecording {
                LevelRow(label: "You", level: taker.micLevel)
                if taker.systemAudio {
                    LevelRow(label: "Them", level: taker.systemLevel)
                } else {
                    Text("Only your microphone is recorded: allow Jarvis under Privacy & Security → Screen & System Audio Recording to hear the other side.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let error = taker.startError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(JcAccent.color)
                            .frame(width: g.size.width * CGFloat(min(1, level * 8)))
                    }
            }
            .frame(height: 5)
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let syncing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(note.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                statusIcon
            }
            Text([note.start.formatted(date: .abbreviated, time: .shortened),
                  "\(max(1, Int((note.duration / 60).rounded()))) min", note.app].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        switch note.status {
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .transcribing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            if syncing || note.summaryStatus == .pending { ProgressView().controlSize(.mini) }
            else if !note.uploaded { Image(systemName: "icloud.slash").foregroundStyle(.secondary).help("Not on the server yet") }
        }
    }
}

private struct NoteDetail: View {
    let note: Note
    let live: Bool
    let syncing: Bool
    @State private var title = ""
    @State private var confirmDelete = false
    private var taker: NoteTaker { NoteTaker.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit { taker.rename(note.id, title: title) }
                        .disabled(live)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                statusBanner
                if let summary = note.summary, !summary.isEmpty {
                    card("Summary") { Text(summary).textSelection(.enabled) }
                }
                if !note.keyPoints.isEmpty {
                    card("Key points") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(note.keyPoints, id: \.self) { p in
                                HStack(alignment: .top, spacing: 6) { Text("•").foregroundStyle(JcAccent.color); Text(p) }
                            }
                        }
                    }
                }
                if !note.todos.isEmpty {
                    card("To-dos") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(note.todos) { todo in
                                Toggle(isOn: Binding(get: { todo.done }, set: { _ in taker.toggleTodo(note.id, todo: todo.id) })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(todo.text).strikethrough(todo.done)
                                        let extra = [todo.owner, todo.due].compactMap { $0 }
                                        if !extra.isEmpty { Text(extra.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                card(live ? "Live transcript" : "Transcript") {
                    if note.lines.isEmpty {
                        Text(live ? "Listening… lines appear after each pause." : "No words.").foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(note.lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(NoteBuilder.clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    Text(note.name(of: line.speaker)).font(.callout.weight(.semibold))
                                        .foregroundStyle(line.speaker == NoteBuilder.meID ? JcAccent.color : .primary)
                                        .frame(width: 44, alignment: .leading)
                                    Text(line.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            // The text wraps to the column; its one-line width never widens it.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { taker.copyMarkdown(note) } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                    .disabled(live)
                Button { taker.export(note) } label: { Label("Export Markdown…", systemImage: "square.and.arrow.up") }
                    .disabled(live)
                Button { taker.summarizeAgain(note.id) } label: { Label("Summarize again", systemImage: "sparkles") }
                    .disabled(live || note.lines.isEmpty || AppModel.shared.apiOrigin == nil || syncing)
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(live)
            }
        }
        .confirmationDialog("Delete “\(note.title)” here and on the server?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { taker.delete(note.id) }
        }
        .onAppear { title = note.title }
        .onChange(of: note.title) { _, t in title = t }
    }

    private var subtitle: String {
        var parts = [note.start.formatted(date: .complete, time: .shortened),
                     "\(max(1, Int((note.duration / 60).rounded()))) min"]
        if let app = note.app { parts.append(app) }
        if !note.speakers.isEmpty { parts.append(note.speakers.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusBanner: some View {
        if note.status == .transcribing {
            banner("Writing the last words…", symbol: "hourglass", color: .secondary)
        } else if let error = note.error {
            banner(error, symbol: "exclamationmark.triangle", color: .orange)
        }
        if note.status == .ready {
            if note.summaryStatus == .pending || (syncing && note.summary == nil) {
                banner("Jarvis is writing the summary…", symbol: "sparkles", color: JcAccent.color)
            } else if note.summaryStatus == .failed {
                banner("The summary failed: \(note.summaryError ?? "no model answered").", symbol: "exclamationmark.triangle", color: .orange)
            } else if !note.uploaded && AppModel.shared.apiOrigin == nil && Prefs.notesUpload {
                banner("Saved on this Mac. It goes to Jarvis (and gets a summary) once jc-client is connected.",
                       symbol: "icloud.slash", color: .secondary)
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.45)))
    }
}
