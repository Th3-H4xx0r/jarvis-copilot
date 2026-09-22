import SwiftUI

/// What Live Jarvis is keeping, and the three deletes of design §3.1.
///
/// Every list is sorted biggest-first (the server sorts, and `LiveStorage` sorts
/// again so the order does not depend on it), and the server's own `note` is
/// rendered verbatim — it is the server that apportioned the bytes, so it is the
/// server's sentence to make.
struct LiveStorageScreen: View {
    @Environment(\.dismiss) private var dismiss
    let store: LiveStore

    @State private var pendingDelete: PendingDelete?

    /// A delete waiting on confirmation. Carries its own wording because the blast
    /// radius differs per kind and a generic "Are you sure?" would hide it.
    private struct PendingDelete: Identifiable {
        let id: String
        let kind: LiveDeleteKind
        let title: String
        let message: String
        let confirm: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                total
                if !store.storage.note.isEmpty { note }
                rows("By session", store.storage.sessions, kind: .session)
                rows("By day", store.storage.days, kind: .day)
                speakers
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .jcScreen("Storage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(JcText.body.weight(.semibold))
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .refreshable { await store.loadStorage() }
        .task { await store.loadStorage() }
        .alert(pendingDelete?.title ?? "", isPresented: Binding(get: { pendingDelete != nil },
                                                               set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { pending in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button(pending.confirm, role: .destructive) {
                Task { await store.delete(kind: pending.kind, id: pending.id) }
                pendingDelete = nil
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var total: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stored audio")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                Text(LiveFormat.bytes(store.storage.totalBytes))
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                Text("Nothing expires on its own. Deleting is always something you do.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The server's explanation, unedited.
    private var note: some View {
        Text(store.storage.note)
            .font(.system(size: 12))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// A group of rows that delete at one granularity.
    ///
    /// `/api/live/delete` takes a `day` kind now — `{"kind":"day","id":"YYYY-MM-DD"}`,
    /// the local calendar day — so the day rows are actionable rather than
    /// decorative, which is what §3.1 asked for.
    @ViewBuilder
    private func rows(_ title: String, _ items: [LiveStorageRow], kind: LiveDeleteKind) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel(title)
                GlassGroup {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                        GlassRow(symbol: kind == .day ? "calendar" : "waveform",
                                 title: kind == .day ? Self.dayLabel(row.label) : row.label,
                                 subtitle: row.detail,
                                 last: index == items.count - 1) {
                            HStack(spacing: 10) {
                                Text(LiveFormat.bytes(row.bytes))
                                    .font(JcText.small)
                                    .foregroundStyle(JcTheme.muted)
                                Button {
                                    pendingDelete = kind == .day
                                        ? dayDelete(row)
                                        : sessionDelete(row, kind: kind)
                                } label: {
                                    JcIcon("trash", size: 14).foregroundStyle(JcTheme.danger)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(row.label)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// `2026-09-21` as "Sunday 21 September". The id stays the raw day — that is
    /// what the server matches on — but a date nobody can read is a poor thing to
    /// ask someone to confirm the deletion of.
    static func dayLabel(_ day: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        // The day is a LOCAL calendar day (the server groups by localtime), so it
        // must be parsed as one; parsing it as UTC shifts the name by a day for
        // anybody west of Greenwich.
        parser.timeZone = .current
        guard let date = parser.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "EEEE d MMMM"
        return out.string(from: date)
    }

    @ViewBuilder
    private var speakers: some View {
        if !store.storage.speakers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("By voice")
                GlassGroup {
                    ForEach(Array(store.storage.speakers.enumerated()), id: \.element.id) { index, row in
                        GlassRow(symbol: "person",
                                 title: row.label,
                                 subtitle: row.approximate
                                    ? "Approximate — a recording holds several people"
                                    : row.detail,
                                 subtitleLineLimit: 2,
                                 last: index == store.storage.speakers.count - 1) {
                            HStack(spacing: 10) {
                                Text((row.approximate ? "≈" : "") + LiveFormat.bytes(row.bytes))
                                    .font(JcText.small)
                                    .foregroundStyle(JcTheme.muted)
                                Menu {
                                    Button("Forget this voice", jcIcon: "person.crop.circle.badge.xmark") {
                                        pendingDelete = forgetDelete(row)
                                    }
                                    Button("Delete every recording they're in",
                                           jcIcon: "trash", role: .destructive) {
                                        pendingDelete = speakerAudioDelete(row)
                                    }
                                } label: {
                                    JcIcon("ellipsis", size: 15).foregroundStyle(JcTheme.muted)
                                }
                                .accessibilityLabel("Delete options for \(row.label)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Confirmations

    private func sessionDelete(_ row: LiveStorageRow, kind: LiveDeleteKind) -> PendingDelete {
        PendingDelete(id: row.id, kind: kind,
                      title: "Delete this session?",
                      message: "Its transcript and its \(LiveFormat.bytes(row.bytes)) of audio go. "
                             + "This is exact — nothing else is affected.",
                      confirm: "Delete")
    }

    /// A day takes EVERY conversation recorded in it, which is more than the row's
    /// own label suggests, so the dialog counts them out loud.
    private func dayDelete(_ row: LiveStorageRow) -> PendingDelete {
        PendingDelete(id: row.id, kind: .day,
                      title: "Delete everything from \(Self.dayLabel(row.label))?",
                      message: "Every session recorded that day goes — each one's "
                             + "transcript, its paired chat, and \(LiveFormat.bytes(row.bytes)) "
                             + "of audio in total. Other days are untouched. This cannot be "
                             + "undone.",
                      confirm: "Delete this day")
    }

    private func forgetDelete(_ row: LiveStorageRow) -> PendingDelete {
        PendingDelete(id: row.id, kind: .speakerForget,
                      title: "Forget \(row.label)?",
                      message: "Their voiceprint and their transcript rows go. The recordings "
                             + "stay, so nobody else loses anything — and this voice will be "
                             + "treated as new if it is heard again.",
                      confirm: "Forget")
    }

    /// The dialog §3.1 insists says it plainly: this takes whole chunks, and a chunk
    /// holds whoever else was in the room.
    private func speakerAudioDelete(_ row: LiveStorageRow) -> PendingDelete {
        PendingDelete(id: row.id, kind: .speakerAudio,
                      title: "Delete every recording \(row.label) appears in?",
                      message: "This deletes WHOLE recordings, not just their part of them — so "
                             + "it takes everyone else's audio in those recordings with it. "
                             + "Transcripts of the other people in them will lose their audio. "
                             + "This cannot be undone.",
                      confirm: "Delete recordings")
    }
}
