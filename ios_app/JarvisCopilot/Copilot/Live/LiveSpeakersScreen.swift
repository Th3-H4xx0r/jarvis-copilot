import SwiftUI

/// Every voice Jarvis has heard: sample utterances so you can tell who it is, and
/// a rename (design §7.1).
///
/// Playback of a sample is deliberately NOT here. The server returns sample text,
/// and there is no per-utterance audio endpoint in the frozen contract — a play
/// button that did nothing would be worse than no play button.
struct LiveSpeakersScreen: View {
    @Environment(\.dismiss) private var dismiss
    let store: LiveStore

    @State private var renaming: LiveSpeaker?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.speakers.isEmpty {
                    JcEmptyState(symbol: "person.2",
                                 title: "No voices yet",
                                 subtitle: "Record a conversation and the voices in it appear here, "
                                         + "ready to be named.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(store.speakers) { speaker in
                        card(speaker)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .jcScreen("Voices")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(JcText.body.weight(.semibold))
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .refreshable { await store.loadSpeakers() }
        .task { await store.loadSpeakers() }
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let speaker = renaming {
                    let name = draft
                    Task { await store.rename(speaker: speaker, to: name) }
                }
                renaming = nil
            }
        } message: {
            Text("The name follows every past and future utterance from this voice.")
        }
    }

    private func card(_ speaker: LiveSpeaker) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    GlassCircleIcon(symbol: speaker.kind == "me" ? "person.fill" : "person",
                                    size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.displayName)
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                        Text(summary(speaker))
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.muted)
                    }
                    Spacer(minLength: 4)
                    Button {
                        draft = speaker.name
                        renaming = speaker
                    } label: {
                        JcIcon("pencil", size: 15).foregroundStyle(JcTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(speaker.displayName)")
                }

                if !speaker.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(speaker.samples.prefix(3).enumerated()), id: \.offset) { _, sample in
                            Text("“" + sample + "”")
                                .font(.system(size: 13))
                                .foregroundStyle(JcTheme.text.opacity(0.78))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Counts and minutes, plus the approximate byte figure — §3.1 is explicit that
    /// per-speaker bytes can only ever be approximate, so the "≈" is not decoration.
    private func summary(_ speaker: LiveSpeaker) -> String {
        var parts: [String] = []
        if speaker.segmentCount > 0 {
            parts.append("\(speaker.segmentCount) utterance\(speaker.segmentCount == 1 ? "" : "s")")
        }
        if speaker.speechMs > 0 {
            let minutes = max(speaker.speechMs / 60000, 0)
            parts.append(minutes >= 1 ? "\(minutes) min of speech" : "\(speaker.speechMs / 1000)s of speech")
        }
        if speaker.audioBytes > 0 {
            parts.append("≈" + LiveFormat.bytes(speaker.audioBytes))
        }
        return parts.isEmpty ? "Heard once" : parts.joined(separator: " · ")
    }
}
