import SwiftUI
import UIKit

/// AI notes recorded through the glasses: start one, watch it transcribe, and read
/// the saved notes with Jarvis's summary and the photos where they were taken.
struct GlassesNotesView: View {
    private let recorder = GlassesNoteRecorder.shared
    private let store = GlassesNotesStore.shared
    @AppStorage(GlassesNoteRecorder.fromGlassesKey) private var fromGlasses = true

    var body: some View {
        List {
            Section {
                Button {
                    Task { await recorder.start() }
                } label: {
                    HStack {
                        Spacer()
                        if recorder.phase == .starting { ProgressView() }
                        Label(recorder.phase == .starting ? "Starting…" : "Start a note", jcIcon: "mic.fill")
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.jcGlass)
                .disabled(recorder.phase != .idle)
                .listRowBackground(Color.clear)
                Toggle("Start from the glasses", isOn: $fromGlasses)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = recorder.problem { Text(problem).foregroundStyle(.red) }
                    Text("The glasses' microphone is transcribed on this phone, the sentence you're saying shows on the lens, and glasses photos land in the note. Jarvis writes the title and summary.")
                }
            }
            Section {
                if store.notes.isEmpty {
                    Text("No notes yet.").foregroundStyle(JcTheme.muted)
                }
                ForEach(store.notes) { note in
                    NavigationLink { GlassesNoteDetailView(noteID: note.id) } label: { row(note) }
                        .swipeActions { Button("Delete", role: .destructive) { store.delete(note.id) } }
                }
            } header: { Text("Notes") }
        }
        .navigationTitle("AI Notes")
        .fullScreenCover(isPresented: .constant(recorder.phase == .recording || recorder.phase == .saving)) {
            GlassesNoteRecordingView()
        }
    }

    private func row(_ note: GlassesNote) -> some View {
        HStack(spacing: 12) {
            if let photo = note.photos.first, let image = UIImage(contentsOfFile: store.url(of: photo, in: note).path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                JcIcon("text.bubble").foregroundStyle(JcTheme.accent).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).foregroundStyle(JcTheme.text).lineLimit(1)
                Text("\(note.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(GlassesNoteFormat.clock(Int(note.duration)))" + (note.photos.isEmpty ? "" : " · \(note.photos.count) photo\(note.photos.count == 1 ? "" : "s")"))
                    .font(.caption).foregroundStyle(JcTheme.muted)
                if note.summary == nil, !note.text.isEmpty {
                    Text(note.text).font(.caption).foregroundStyle(JcTheme.muted).lineLimit(1)
                }
            }
        }
    }
}

/// The screen while a note is recording: timer, live transcript, photos, Save.
struct GlassesNoteRecordingView: View {
    private let recorder = GlassesNoteRecorder.shared
    private let store = GlassesNotesStore.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text(recorder.phase == .saving ? "Saving…" : "Recording from the glasses")
                    .font(.subheadline.weight(.medium)).foregroundStyle(JcTheme.muted)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                            .font(.title3).foregroundStyle(recorder.transcript.isEmpty ? JcTheme.muted : JcTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !recorder.photos.isEmpty, let id = recorder.noteID {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(recorder.photos) { photo in
                                        if let image = UIImage(contentsOfFile: store.folder(id).appendingPathComponent(photo.file).path) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                                .frame(width: 120, height: 90)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: recorder.transcript) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(GlassesNoteFormat.clock(recorder.elapsed)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("/ 60:00").foregroundStyle(JcTheme.muted)
                Spacer()
            }
            HStack(spacing: 12) {
                Button("Discard", jcIcon: "trash", action: { recorder.discard() })
                    .buttonStyle(.jcGlass(tint: .red, compact: true))
                    .disabled(recorder.phase != .recording)
                Button {
                    Task { await recorder.save() }
                } label: {
                    HStack { Spacer(); Text("Save").font(.headline); Spacer() }.padding(.vertical, 6)
                }
                .buttonStyle(.jcGlass)
                .disabled(recorder.phase != .recording)
            }
            Text("Take photos with the glasses button — they show up in the note.")
                .font(.caption).foregroundStyle(JcTheme.muted)
        }
        .padding(20)
        .background(Color.black.ignoresSafeArea())
    }
}

/// A saved note: Jarvis's summary, then the transcript with photos where they were taken.
struct GlassesNoteDetailView: View {
    let noteID: String
    private let store = GlassesNotesStore.shared
    @State private var working: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let note = store.note(noteID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(.title2.weight(.semibold)).foregroundStyle(JcTheme.text)
                        Text("\(note.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(GlassesNoteFormat.clock(Int(note.duration)))")
                            .font(.subheadline).foregroundStyle(JcTheme.muted)
                    }
                    summary(note)
                    if note.photos.contains(where: { $0.source == .glasses && !$0.fullSize }) {
                        Button(working == "photos" ? "Getting full photos…" : "Get full-size photos from the glasses", jcIcon: "photo.on.rectangle") {
                            run("photos") { await GlassesNoteFinisher.fetchPhotos(noteID: noteID, store: store) }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(working != nil)
                    }
                    Text("Transcript").font(.headline).foregroundStyle(JcTheme.text)
                    if note.segments.isEmpty && note.photos.isEmpty {
                        Text(note.text.isEmpty ? "Nothing was heard." : note.text).foregroundStyle(JcTheme.text)
                    }
                    ForEach(note.timeline) { item in
                        switch item {
                        case .text(let segment):
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(GlassesNoteFormat.clock(segment.ms / 1000)).font(.caption.monospacedDigit()).foregroundStyle(JcTheme.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(segment.text).foregroundStyle(JcTheme.text)
                                    if let translation = segment.translation, !translation.isEmpty {
                                        Text(translation).font(.body.weight(.semibold)).foregroundStyle(JcTheme.accent)
                                    }
                                }
                            }
                        case .photo(let photo):
                            if let image = UIImage(contentsOfFile: store.url(of: photo, in: note).path) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(GlassesNoteFormat.clock(photo.ms / 1000) + (photo.fullSize ? "" : " · preview"))
                                            .font(.caption2).padding(6).background(.black.opacity(0.5), in: Capsule()).padding(8)
                                    }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: GlassesNoteFormat.shareText(note)) { Label("Share", jcIcon: "square.and.arrow.up") }
                        Button("Delete", jcIcon: "trash", role: .destructive) { store.delete(noteID); dismiss() }
                    } label: { JcIcon("ellipsis.circle") }
                }
            }
        } else {
            Text("This note was deleted.").foregroundStyle(JcTheme.muted)
        }
    }

    @ViewBuilder private func summary(_ note: GlassesNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Jarvis summary", jcIcon: "sparkles").font(.headline).foregroundStyle(JcTheme.accent)
            if let summary = note.summary {
                Text((try? AttributedString(markdown: summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(summary))
                    .foregroundStyle(JcTheme.text)
            } else if note.text.isEmpty {
                Text("Nothing to summarise.").foregroundStyle(JcTheme.muted)
            } else {
                Button(working == "summary" ? "Jarvis is writing…" : "Summarise with Jarvis", jcIcon: "sparkles") {
                    run("summary") { await GlassesNoteFinisher.summarize(noteID: noteID, store: store) }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(working != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func run(_ job: String, _ body: @escaping () async -> Void) {
        working = job
        Task { await body(); working = nil }
    }
}

enum GlassesNoteFormat {
    static func clock(_ seconds: Int) -> String { String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
    static func shareText(_ note: GlassesNote) -> String {
        [note.title, note.summary, "Transcript:\n" + note.text].compactMap { $0 }.joined(separator: "\n\n")
    }
}
