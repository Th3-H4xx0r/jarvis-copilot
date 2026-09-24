import SwiftUI

/// Every voice Jarvis has heard: sample utterances so you can tell who it is, a
/// rename, and a merge for the times it heard one person as two (design §7.1).
///
/// Playback of a sample is deliberately NOT here. The server returns sample text,
/// and there is no per-utterance audio endpoint in the frozen contract — a play
/// button that did nothing would be worse than no play button.
struct LiveSpeakersScreen: View {
    @Environment(\.dismiss) private var dismiss
    let store: LiveStore

    @State private var renaming: LiveSpeaker?
    @State private var draft = ""

    /// Merge mode: the cards become a two-of-N picker instead of a list.
    @State private var merging = false
    /// Speaker ids in tap order, at most two.
    @State private var picked: [String] = []
    /// The user overrode which of the pair survives.
    @State private var swapped = false
    @State private var confirming = false

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
                    if merging {
                        Text("Pick the two voices that are the same person.")
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.muted)
                            .padding(.horizontal, 4)
                    }
                    ForEach(store.speakers) { speaker in
                        if merging {
                            Button { toggle(speaker) } label: { card(speaker) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isPicked(speaker) ? [.isSelected] : [])
                        } else {
                            card(speaker)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .jcScreen("Voices")
        .animation(.easeInOut(duration: 0.18), value: merging)
        .animation(.easeInOut(duration: 0.18), value: picked)
        .toolbar {
            // Merge lives in the toolbar rather than on each card: it is a claim
            // about a PAIR, and a per-card button would have to invent a second
            // step anyway to ask "the same as which one?".
            ToolbarItem(placement: .topBarLeading) {
                if store.speakers.count >= 2 {
                    Button(merging ? "Cancel" : "Merge") { setMerging(!merging) }
                        .font(JcText.body.weight(merging ? .regular : .semibold))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(JcText.body.weight(.semibold))
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .safeAreaInset(edge: .bottom) { mergeBar }
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
        .alert("Merge these two voices?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Merge") { commit() }
        } message: {
            // Both names, and what happens to the history — a merge rewrites the
            // past, so the sentence says so before it happens rather than after.
            if let pair {
                Text("“\(pair.folded.displayName)” becomes “\(pair.survivor.displayName)”. "
                   + "Every utterance already labelled “\(pair.folded.displayName)” is "
                   + "relabelled, in this conversation and every earlier one. "
                   + "This can't be undone.")
            }
        }
    }

    // MARK: - The pair

    private var pickedSpeakers: [LiveSpeaker] {
        picked.compactMap { id in store.speakers.first { $0.id == id } }
    }

    /// Which voice survives and which is folded into it. The default comes from
    /// `LiveStore.survivorOfMerge` — a named voice beats an unnamed one — and the
    /// user can flip it, so the direction is always stated rather than guessed at.
    private var pair: (survivor: LiveSpeaker, folded: LiveSpeaker)? {
        let chosen = pickedSpeakers
        guard chosen.count == 2 else { return nil }
        let preferred = LiveStore.survivorOfMerge(chosen[0], chosen[1])
        let other = preferred.id == chosen[0].id ? chosen[1] : chosen[0]
        return swapped ? (survivor: other, folded: preferred)
                       : (survivor: preferred, folded: other)
    }

    private func isPicked(_ speaker: LiveSpeaker) -> Bool { picked.contains(speaker.id) }

    private func toggle(_ speaker: LiveSpeaker) {
        // A new pair gets the default direction back; silently keeping a flip
        // from the previous pair would merge the wrong way round.
        swapped = false
        if let index = picked.firstIndex(of: speaker.id) {
            picked.remove(at: index)
            return
        }
        if picked.count >= 2 { picked.removeFirst() }
        picked.append(speaker.id)
    }

    private func setMerging(_ on: Bool) {
        merging = on
        picked.removeAll()
        swapped = false
    }

    private func commit() {
        guard let pair else { return }
        let folded = pair.folded, survivor = pair.survivor
        setMerging(false)
        Task { await store.merge(folded, into: survivor) }
    }

    // MARK: - The bar

    @ViewBuilder
    private var mergeBar: some View {
        if merging {
            VStack(spacing: 10) {
                if let pair {
                    // Which one survives, spelled out and swappable. "Keeping" is
                    // the word that matters, so it leads.
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keeping")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(JcTheme.muted)
                            Text(pair.survivor.displayName)
                                .font(JcText.body.weight(.semibold))
                                .foregroundStyle(JcTheme.text)
                                .lineLimit(1)
                            Text("“\(pair.folded.displayName)” folds into it")
                                .font(JcText.small)
                                .foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { swapped.toggle() } label: {
                            JcIcon("arrow.left.arrow.right", size: 15)
                                .foregroundStyle(JcTheme.accent)
                                .frame(width: 40, height: 40)
                                .jcLiquidGlass(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Keep “\(pair.folded.displayName)” instead")
                    }
                } else {
                    Text(picked.count == 1
                         ? "Now pick the other one."
                         : "Pick two voices.")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button { confirming = true } label: {
                    Text("Merge")
                        .font(JcText.body.weight(.semibold))
                        .foregroundStyle(pair == nil ? JcTheme.muted : JcTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(pair == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - A voice

    private func card(_ speaker: LiveSpeaker) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if merging {
                        JcIcon(isPicked(speaker) ? "checkmark.circle.fill" : "circle", size: 20)
                            .foregroundStyle(isPicked(speaker) ? JcTheme.accent : JcTheme.muted)
                    }
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
                    // Hidden while picking: in merge mode the whole card is the
                    // control, and a second tappable thing inside it would make
                    // the outer tap ambiguous.
                    if !merging {
                        Button {
                            draft = speaker.name
                            renaming = speaker
                        } label: {
                            JcIcon("pencil", size: 15).foregroundStyle(JcTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename \(speaker.displayName)")
                    }
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

                // Not in merge mode: there the whole card is the control.
                if !merging, speaker.segmentCount > 0 {
                    NavigationLink {
                        LiveVoiceHistoryScreen(name: speaker.displayName,
                                               history: store.voiceHistory(speakerID: speaker.id))
                    } label: {
                        HStack(spacing: 6) {
                            Text("Everything they said")
                                .font(JcText.small.weight(.semibold))
                                .foregroundStyle(JcTheme.accent)
                            Spacer(minLength: 4)
                            JcIcon("chevron.right", size: 12)
                                .foregroundStyle(JcTheme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if merging, isPicked(speaker) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(JcTheme.accent.opacity(0.6), lineWidth: 1.5)
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


/// Everything one voice has said, newest first, grouped by conversation — the
/// next page loads as the last line comes on screen.
struct LiveVoiceHistoryScreen: View {
    let name: String
    @State var history: LiveVoiceHistory

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(history.total == 1 ? "1 line" : "\(history.total) lines")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .padding(.bottom, 6)
                ForEach(Array(history.lines.enumerated()), id: \.element.id) { index, line in
                    if index == 0 || history.lines[index - 1].sessionID != line.sessionID {
                        Text(line.sessionTitle.isEmpty ? "Live session" : line.sessionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(JcTheme.muted)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                    }
                    row(line)
                        .onAppear {
                            if index == history.lines.count - 1 { Task { await history.loadMore() } }
                        }
                }
                footer
                    .padding(.vertical, 18)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .jcScreen(name)
        .task { if history.lines.isEmpty { await history.loadMore() } }
    }

    private func row(_ line: LiveSpeakerLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.at.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
            Text(line.text)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let translation = line.translation {
                Text(translation)
                    .font(.system(size: 14).italic())
                    .foregroundStyle(JcTheme.text.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(JcTheme.muted.opacity(0.15)).frame(height: 0.5) }
    }

    @ViewBuilder
    private var footer: some View {
        if !history.error.isEmpty {
            VStack(spacing: 8) {
                Text(history.error).font(JcText.small).foregroundStyle(JcTheme.muted)
                Button("Retry") { Task { await history.loadMore() } }
                    .buttonStyle(.jcGlass(compact: true))
            }
            .frame(maxWidth: .infinity)
        } else if history.done {
            Text(history.lines.isEmpty ? "Nothing heard from this voice yet." : "That is everything this voice has said.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .frame(maxWidth: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}
