import Combine
import SwiftUI
#if canImport(Translation)
import Translation
#endif
#if os(iOS)
import UIKit
#endif

/// Live Jarvis: the ambient transcript, in place of the Voice orb.
///
/// Design §7.1 — speaker chip, timestamp, text, translation beneath when present;
/// insight cards visually distinct from utterances; a status line carrying the
/// recording state and the stored-audio total.
struct LiveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store: LiveStore
    @State private var showSettings = false
    @State private var showSpeakers = false
    @State private var showStorage = false
    @State private var naming: LiveSegment?
    @State private var nameDraft = ""
    @State private var discarding = false
    /// Follow the newest row unless the user has scrolled up to read.
    @State private var pinnedToBottom = true

    /// A view's `init` is not main-actor isolated, so the store cannot be a default
    /// argument — the same reason `VoicePage.init` takes an optional.
    init(store: LiveStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { LiveStore.shared })
    }

    /// Matches `VoicePage.controlsGap`: the shell's tab bar floats over the
    /// bottom of every page, so a control row needs clearance from it.
    private static let controlsGap: CGFloat = 14

    /// The control row now carries FOUR tiles beside Record (Fact-check,
    /// Voices, Storage, Settings), so the tiles and the gaps were tightened
    /// from 62/10 to leave Record a readable width on a 4.7" screen.
    private static let tileWidth: CGFloat = 54
    private static let controlGap: CGFloat = 8

    /// Recent input levels, oldest first, for the tape. Cleared when capture
    /// stops so a stopped meter cannot show a moving room.
    @State private var levels: [Double] = []
    /// Re-renders the clock. Bound to the same tick as the tape so the two
    /// never disagree about how long this has been running.
    ///
    /// The clock's ORIGIN is `store.captureStartedAt`, not a `Date` kept here:
    /// the tab-bar indicator and the Live Activity read the store's, and two
    /// origins for one recording is two answers to "how long".
    @State private var tick = Date()

    var body: some View {
        VStack(spacing: 0) {
            roomMeter
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if let halt = store.halt {
                haltBanner(halt)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else if !store.warningText.isEmpty {
                warningBanner(store.warningText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            transcript

            controls
                .padding(.horizontal, 20)
                .padding(.top, 12)
                // The tab bar floats over this, so without a gap the buttons
                // read as part of it. Same 14pt VoicePage leaves.
                .padding(.bottom, Self.controlsGap)
        }
        .task { await store.load() }
        // On-device translation for a pair whose language pack is NOT installed:
        // only a session from this modifier can ask to download one. Installed
        // pairs translate without any view (`InstalledTranslationSessions`).
        .liveTranslation(store.translator)
        // Any model download or preparation, where it can be seen.
        .liveModelPopup(store)
        .sheet(isPresented: $showSettings) {
            LiveSettingsSheet(store: store)
        }
        .sheet(isPresented: $showSpeakers) {
            NavigationStack { LiveSpeakersScreen(store: store) }
        }
        .sheet(isPresented: $showStorage) {
            NavigationStack { LiveStorageScreen(store: store) }
        }
        .alert("Name this voice", isPresented: Binding(get: { naming != nil },
                                                      set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") {
                if let segment = naming {
                    let name = nameDraft
                    Task { await store.nameVoice(of: segment, as: name) }
                }
                naming = nil
            }
        } message: {
            Text("Everything this voice has said, and everything it says from now on, "
               + "will carry the name.")
        }
        .alert("Discard unsent audio?", isPresented: $discarding) {
            Button("Keep it", role: .cancel) {}
            Button("Discard", role: .destructive) { store.discardBacklog() }
        } message: {
            Text("This permanently deletes the part of the conversation that never reached "
               + "Jarvis. It cannot be recovered.")
        }
        // Above the controls, never on them: pinned to .bottom it covered the
        // very buttons it was reporting about, including Stop.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.error.isEmpty {
                errorToast(store.error)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Status

    /// The one thing this screen must answer at a glance: is the room being
    /// heard, for how long, and how much has been kept. It replaced a thin
    /// capsule that said "Not recording · No audio stored yet" (the same fact
    /// twice) with a settings gear stranded at the far edge.
    private var roomMeter: some View {
        let split = LiveRecorderStatus.split(store.statusText)
        return LiveRoomMeter(state: captureState,
                             headline: split.headline,
                             detail: split.detail,
                             kept: store.storageText,
                             elapsed: elapsed,
                             tape: levels,
                             notice: store.sttNotice)
            .onChange(of: store.capturing) { _, capturing in
                if !capturing { levels = [] }
            }
            // Sampling only while capturing matters: every tab stays mounted in
            // the shell, so an ungated ticker would run behind all five.
            .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                guard store.capturing else { return }
                levels.append(store.level)
                if levels.count > 64 { levels.removeFirst(levels.count - 64) }
                tick = Date()
            }
    }

    private var elapsed: TimeInterval? {
        guard let startedAt = store.captureStartedAt, store.capturing else { return nil }
        return max(0, tick.timeIntervalSince(startedAt))
    }

    private var captureState: LiveCaptureState {
        if store.halt != nil { return .stopped }
        if store.capturing { return store.interrupted ? .paused : .recording }
        return .idle
    }

    /// The loud state of §8. A red card that stays until dismissed, because the
    /// alternative — a quiet line in a status pill — is how hours go missing.
    private func haltBanner(_ halt: LiveHalt) -> some View {
        GlassCard(fill: JcTheme.danger.opacity(0.14),
                  borderColor: JcTheme.danger.opacity(0.45)) {
            HStack(alignment: .top, spacing: 12) {
                JcIcon("exclamationmark.triangle", size: 19)
                    .foregroundStyle(JcTheme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text(halt.title)
                        .font(JcText.body.weight(.semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(halt.detail)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { store.clearHalt() } label: {
                    JcIcon("xmark", size: 13).foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func warningBanner(_ text: String) -> some View {
        GlassCard(padding: 12,
                  fill: JcTheme.amber.opacity(0.10),
                  borderColor: JcTheme.amber.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    JcIcon("exclamationmark.circle", size: 15).foregroundStyle(JcTheme.amber)
                    Text(text)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // The ONLY way unsent conversation is deleted is the user asking for
                // it here. Everything else keeps it and retries.
                if store.spooledFrames > 0, !store.capturing {
                    Button("Discard what hasn't uploaded") { discarding = true }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(JcTheme.danger)
                }
            }
        }
    }

    // MARK: - Where the fact-check card goes

    /// The verdict, when the server tied it to a row that is actually on screen.
    ///
    /// Both conditions matter. No anchor means the check read a window and
    /// belongs to no single line. An anchor pointing at a row we do not have —
    /// scrolled out of a truncated transcript, or a session resumed past it —
    /// would make the card disappear entirely, so it falls back to the end.
    private var anchoredFactCheck: LiveFactCheckResult? {
        guard let result = store.factCheck, !result.pending, let seq = result.anchorSeq,
              store.rows.contains(where: {
                  if case .segment(let segment) = $0 { return segment.seq == seq }
                  return false
              })
        else { return nil }
        return result
    }

    /// The same verdict when it has nowhere better to go — and always the
    /// loading card, which has no anchor yet and rises to meet its verdict when
    /// one lands.
    private var trailingFactCheck: LiveFactCheckResult? {
        guard let result = store.factCheck else { return nil }
        return anchoredFactCheck == nil ? result : nil
    }

    /// The wrap-up, when the utterance it closes is on screen.
    private var anchoredWrapUp: LiveWrapUp? {
        guard let wrap = store.wrapUp, let seq = wrap.afterSeq,
              store.rows.contains(where: {
                  if case .segment(let segment) = $0 { return segment.seq == seq }
                  return false
              })
        else { return nil }
        return wrap
    }

    /// The same wrap-up when it has nowhere to sit, so it closes the list
    /// rather than disappearing.
    private var trailingWrapUp: LiveWrapUp? {
        guard let wrap = store.wrapUp else { return nil }
        return anchoredWrapUp == nil ? wrap : nil
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if store.rows.isEmpty && store.partialText.isEmpty && store.committingText.isEmpty
            && store.wrapUp == nil && store.factCheck == nil {
            VStack {
                Spacer()
                JcEmptyState(symbol: "waveform",
                             title: store.capturing ? "Listening to the room" : "Nothing captured yet",
                             subtitle: store.capturing
                                ? "Utterances appear here as people speak."
                                : "Start recording and the conversation appears here, "
                                + "labelled by voice.")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.rows) { row in
                            switch row {
                            case .segment(let segment):
                                LiveSegmentRow(segment: segment,
                                               onTranslate: { Task { await store.translate(segment) } },
                                               onName: {
                                                   nameDraft = segment.speakerName ?? ""
                                                   naming = segment
                                               })
                                // A verdict the server tied to THIS line reads
                                // under it. Against the sentence it judged, the
                                // card needs no preamble explaining which claim
                                // it means.
                                if let anchored = anchoredFactCheck,
                                   anchored.anchorSeq == segment.seq {
                                    LiveFactCheckCard(result: anchored)
                                        .padding(.top, 2)
                                }
                                // The wrap-up closes the conversation it
                                // summarised — and anything said afterwards
                                // belongs underneath it, not above.
                                if let wrap = anchoredWrapUp,
                                   wrap.afterSeq == segment.seq {
                                    LiveWrapUpCard(wrap: wrap)
                                        .padding(.top, 2)
                                }
                            case .insight(let insight):
                                LiveInsightCard(insight: insight)
                            }
                        }
                        // The line that just ended, on its way to the server.
                        // It goes the moment its committed row arrives.
                        if !store.committingText.isEmpty {
                            LiveProvisionalRow(text: store.committingText,
                                               startMs: store.committingStartMs)
                                .transition(.opacity)
                        }
                        // The words being spoken right now, from this phone's
                        // own recogniser. Always last, because it is by
                        // definition the newest thing said.
                        if !store.partialText.isEmpty {
                            LiveProvisionalRow(text: store.partialText,
                                               startMs: store.partialStartMs)
                                .id(Self.partialAnchor)
                                .transition(.opacity)
                        }
                        // A verdict about the whole window — or one still being
                        // worked out — sits at the end of the conversation
                        // rather than against any one line.
                        if let result = trailingFactCheck {
                            LiveFactCheckCard(result: result)
                                .padding(.top, 4)
                        }
                        // Only when it belongs to no row on screen — a
                        // wrap-up written before this device joined, or whose
                        // last utterance has scrolled out of a trimmed
                        // transcript. Otherwise it is already inline above.
                        if let wrap = trailingWrapUp {
                            LiveWrapUpCard(wrap: wrap)
                                .padding(.top, 4)
                        }
                        // An anchor to scroll to, so following the newest row does
                        // not depend on the last row's identity (which changes when
                        // a provisional row is replaced).
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .scrollDismissesKeyboard(.interactively)
                // Opening the page — or a conversation — lands on its newest
                // line. This scroll view is created when the first rows arrive
                // (before that the empty state stands in its place), so its
                // appearance IS "the transcript loaded". Twice, because a lazy
                // stack only knows its real height after the first layout.
                .onAppear {
                    pinnedToBottom = true
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                }
                .onChange(of: store.rows.count) { _, _ in
                    guard pinnedToBottom else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                // Everything else that grows the bottom while someone speaks: the
                // live words, the line on its way to the server, the last row
                // being corrected or gaining its translation. Following only the
                // row COUNT left all of that growing below the fold. Unanimated:
                // the text grows word by word, and an ease on every word reads as
                // the transcript sliding about rather than as speech arriving.
                .onChange(of: tailSignature) { _, _ in
                    guard pinnedToBottom else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                // Dragging is taken as "I am reading"; the newest row stops pulling
                // the view away from what the user is looking at.
                .simultaneousGesture(DragGesture().onChanged { value in
                    if value.translation.height > 12 { pinnedToBottom = false }
                })
                // ...and scrolling back down to the end is taken as "follow
                // again", which the drag rule alone never allowed: only the
                // arrow button could re-pin.
                .modifier(LiveFollowsBottom(pinned: $pinnedToBottom))
                .overlay(alignment: .bottomTrailing) {
                    if !pinnedToBottom {
                        Button {
                            pinnedToBottom = true
                            withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                        } label: {
                            JcIcon("arrow.down", size: 15)
                                .foregroundStyle(JcTheme.accent)
                                .frame(width: 36, height: 36)
                                .jcLiquidGlass(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 22)
                        .padding(.bottom, 8)
                        .accessibilityLabel("Jump to the newest")
                    }
                }
            }
        }
    }

    private static let bottomAnchor = "live-bottom"
    private static let partialAnchor = "live-partial"

    /// Changes whenever the bottom of the transcript grows without a row being
    /// added.
    private var tailSignature: Int {
        var hasher = Hasher()
        hasher.combine(store.partialText)
        hasher.combine(store.committingText)
        if case .segment(let last)? = store.rows.last {
            hasher.combine(last.seq)
            hasher.combine(last.text)
            hasher.combine(last.translation)
        }
        return hasher.finalize()
    }

    // MARK: - Controls

    /// Record, then the four things you can do to a conversation.
    ///
    /// Fact-check lives HERE, beside Record, because it is about the
    /// conversation. It used to be a control on every transcript row, which was
    /// both unreadable and meaningless — checking one utterance of "Yo, one,
    /// two, three, hello" answers nothing.
    private var controls: some View {
        HStack(spacing: Self.controlGap) {
            if store.readOnly {
                // Looking at a conversation that is over. Record is not shown
                // rather than shown-and-refused: a finished session cannot be
                // appended to, and offering it would be an invitation to fail.
                Button { store.stopViewing() } label: {
                    HStack(spacing: 8) {
                        JcIcon("arrow.uturn.left", size: 16)
                        Text("Back to live").font(JcText.body.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(JcTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task {
                        if store.capturing { await store.stop() } else { await store.start() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        JcIcon(store.capturing ? "stop.fill" : "record.circle", size: 16)
                        Text(store.capturing ? "Stop" : "Record")
                            .font(JcText.body.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(store.capturing ? JcTheme.danger : JcTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.halt != nil)
                .opacity(store.halt == nil ? 1 : 0.5)
            }

            factCheckTile
            secondary("person.2", "Voices") { showSpeakers = true }
            secondary("internaldrive", "Storage") { showStorage = true }
            secondary("gear", "Settings") { showSettings = true }
        }
    }

    /// Fact-check the recent conversation.
    ///
    /// The running state is a REAL spinner filling the tile, not a change of
    /// shade: the request is a full agent turn with web tools and can sit there
    /// for seconds, and "there should be a loading indicator over the button"
    /// is what happens when it isn't obvious.
    private var factCheckTile: some View {
        Button {
            Task { await store.factCheckConversation() }
        } label: {
            VStack(spacing: 3) {
                if store.checkingConversation {
                    ProgressView()
                        .controlSize(.small)
                        .tint(JcTheme.accent)
                        .frame(height: 16)
                } else {
                    JcIcon("checkmark.seal", size: 16)
                }
                Text(store.checkingConversation ? "Checking" : "Fact-check")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(store.checkingConversation
                             ? JcTheme.accent : JcTheme.text.opacity(0.82))
            .frame(width: Self.tileWidth, height: 52)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                // A visible ring while it runs, so the control itself reads as
                // busy from across the room and not only by its label.
                if store.checkingConversation {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(JcTheme.accent.opacity(0.55), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.checkingConversation || store.rows.isEmpty)
        .opacity(store.rows.isEmpty && !store.checkingConversation ? 0.45 : 1)
        .accessibilityLabel(store.checkingConversation
                            ? "Checking the recent conversation"
                            : "Fact-check the recent conversation")
        .accessibilityHint("Asks Jarvis to check what has just been said and adds its "
                         + "verdict at the end of the transcript. Nothing is checked "
                         + "until you tap this.")
    }

    /// A glyph on its own was unguessable — a drive for Storage, two people for
    /// Voices — so each says its word. `buttons.md › Best practices` wants a
    /// control both reachable and "instantly recognizable".
    private func secondary(_ symbol: String, _ title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                JcIcon(symbol, size: 16)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(JcTheme.text.opacity(0.82))
            .frame(width: Self.tileWidth, height: 52)
            .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Tappable to dismiss. An error with no way out sits over the transcript for the
    /// rest of the session, and the store is a process-wide singleton, so "the rest of
    /// the session" means until the app is relaunched.
    private func errorToast(_ text: String) -> some View {
        Button { store.dismissError() } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.leading)
                JcIcon("xmark", size: 11).foregroundStyle(JcTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(JcTheme.surfaceAlt, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .transition(.opacity)
        .accessibilityLabel("\(text). Tap to dismiss.")
    }
}

// MARK: - Rows

/// One utterance: who, when, what was said, and the translation beneath it when
/// the server filled one in.
struct LiveSegmentRow: View {
    let segment: LiveSegment
    let onTranslate: () -> Void
    let onName: () -> Void

    private var speaker: String {
        LiveFormat.speakerLabel(id: segment.speakerID, name: segment.speakerName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(speaker)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(chipTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(chipTint.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(chipTint.opacity(0.30), lineWidth: 1))
                // A provisional label may still be relabelled, including
                // retroactively by a merge. Saying so is the difference between
                // "Jarvis is unsure" and "Jarvis got it wrong".
                if segment.labelState == .provisional {
                    Text("unconfirmed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 4)
                Text(LiveFormat.stamp(ms: segment.startMs))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(JcTheme.muted)
            }

            Text(segment.text)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let translation = segment.translation {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 6) {
                        JcIcon("globe", size: 11).foregroundStyle(JcTheme.muted)
                        Text(translation)
                            .font(.system(size: 13.5))
                            .foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Which language this came out of. Without it a line of
                    // English under a line of Chinese characters is just two
                    // sentences, and there is no way to tell a translation
                    // from a correction.
                    if let trip = LiveLanguageName.trip(from: segment.lang) {
                        Text(trip)
                            .font(.system(size: 11))
                            .foregroundStyle(JcTheme.muted.opacity(0.75))
                            .padding(.leading, 17)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // No fact-check here, deliberately. Checking one utterance was
        // meaningless on a line like "Yo, one, two, three, hello", and a
        // control on every row made the transcript unreadable. The check now
        // reads a window of the CONVERSATION, from the button beside Record.
        .contextMenu {
            Button("Translate", jcIcon: "globe", action: onTranslate)
            Button("Copy", jcIcon: "doc.on.doc") {
                LivePasteboard.copy(segment.text)
            }
            Button("Name this voice", jcIcon: "person.crop.circle", action: onName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker) at \(LiveFormat.stamp(ms: segment.startMs)): \(segment.text)")
    }


    /// A confirmed voice gets the accent; an unconfirmed one stays neutral, so the
    /// colour carries the confidence rather than only the word beside it.
    private var chipTint: Color {
        segment.labelState == .confirmed ? JcTheme.accent : JcTheme.muted
    }
}

/// The utterance being spoken RIGHT NOW, from this phone's own recogniser.
///
/// Deliberately unlike `LiveSegmentRow`, because it is a different KIND of
/// thing: a guess that is about to be replaced. No speaker chip (nobody has
/// been identified yet), dimmer text, and a leading caret so it reads as
/// in-progress rather than as a line someone actually said and Jarvis got
/// wrong. It carries no actions at all — fact-checking, naming or translating a
/// sentence that is still being said would address a row the server has never
/// heard of.
struct LiveProvisionalRow: View {
    let text: String
    let startMs: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("speaking")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(JcTheme.glassFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                Spacer(minLength: 4)
                Text(LiveFormat.stamp(ms: startMs))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(JcTheme.muted)
            }
            Text(text)
                .font(.system(size: 15))
                // Dimmer than a committed row: the difference between "this is
                // the record" and "this is what Jarvis is hearing".
                .foregroundStyle(JcTheme.text.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        // Announced as it grows, so a screen-reader user hears the room too.
        .accessibilityLabel("Being spoken: \(text)")
    }
}

/// Jarvis's verdict on the recent conversation — or the honest news that it
/// could not reach one.
///
/// Same card shape as the wrap-up, because it is the same kind of thing: an
/// answer about the conversation as a whole, sitting at the end of it. Two
/// things it must never do: present a FAILED check as a completed one, and
/// print the provider's own words at the user (he was shown
/// `API call failed after 3 retries: HTTP 404: model "" not found`, which is
/// developer text, and worse, was dressed up as a verdict).
struct LiveFactCheckCard: View {
    let result: LiveFactCheckResult

    private var failed: Bool { result.failed }
    private var pending: Bool { result.pending }

    /// Three states, three colours, and the distinctions between them are the
    /// point:
    ///
    ///  * **Red** only when the check came back and said the claim is FALSE.
    ///    The verdict is free text from a model, so `isRefuted` matches a small
    ///    exact set — "misleading" and "unverifiable" are not refutations and
    ///    stay neutral.
    ///  * **Amber** for a check that did NOT run. "We couldn't check" is not
    ///    "this is false", and painting a failure red would tell the user
    ///    something no check ever said.
    ///  * **Accent** for everything else, including while it is still running.
    private var tint: Color {
        if failed { return JcTheme.amber }
        return result.isRefuted ? JcTheme.danger : JcTheme.accent
    }

    private var title: String {
        if pending { return "Checking" }
        return failed ? "Couldn't check" : "Fact-check"
    }

    private var symbol: String {
        if failed { return "exclamationmark.circle" }
        return result.isRefuted ? "xmark.seal" : "checkmark.seal"
    }

    /// Standing in for the verdict until it arrives — same card, same place, so
    /// it becomes the answer rather than being replaced by it.
    private var pendingText: String {
        "Reading the recent conversation and checking what was said."
    }

    /// A screen reader gets the same three states, in words — including the
    /// refutation, which is the one a colour alone would not convey.
    private var accessibilityText: String {
        if pending { return "Fact-check running. \(pendingText)" }
        if failed { return "Fact-check did not complete. \(result.text)" }
        if result.isRefuted { return "Fact-check says this is false. \(result.text)" }
        return "Fact-check verdict. \(result.text)"
    }

    var body: some View {
        GlassCard(padding: 15,
                  fill: tint.opacity(0.10),
                  borderColor: tint.opacity(0.32)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if pending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                            .frame(width: 14, height: 14)
                    } else {
                        JcIcon(symbol, size: 14)
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    // The grade only exists when there IS one.
                    if !failed, !pending, !result.verdict.isEmpty {
                        Text(result.verdict.capitalized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(tint.opacity(0.16), in: Capsule())
                    }
                }
                Text(pending ? pendingText : result.text)
                    .font(.system(size: 14))
                    .foregroundStyle(pending ? JcTheme.muted : JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !result.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sources")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                        ForEach(Array(result.sources.enumerated()), id: \.offset) { _, source in
                            Text(source)
                                .font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                if !failed, !pending {
                    Text("Checked the recent conversation, not the whole recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(JcTheme.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }
}

/// The end of a session: the summary, the decisions and the action items the
/// artifacts watcher wrote.
///
/// This also goes into the paired chat (the server does that, by design), but
/// the screen that produced the conversation used to be the one place its
/// conclusion never appeared — so it closes the transcript here as well.
struct LiveWrapUpCard: View {
    let wrap: LiveWrapUp

    var body: some View {
        GlassCard(padding: 15,
                  fill: JcTheme.accent.opacity(0.10),
                  borderColor: JcTheme.accent.opacity(0.32)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    JcIcon("doc.text", size: 14).foregroundStyle(JcTheme.accent)
                    Text("Conversation wrap-up")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(JcTheme.accent)
                    Spacer(minLength: 0)
                }
                // The structured fields when the server sent them; its own
                // rendered markdown when it sent only that.
                if wrap.summary.isEmpty, wrap.decisions.isEmpty, wrap.actionItems.isEmpty {
                    paragraph(wrap.text)
                } else {
                    if !wrap.summary.isEmpty { paragraph(wrap.summary) }
                    list("Decisions", wrap.decisions)
                    list("Action items", wrap.actionItems)
                }
                Text("Also in Chats, where you can ask about it later.")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Not called `body` — that name is the `View` requirement.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(JcTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        // A real bullet rather than a dash, and hidden from
                        // VoiceOver so a list is not read as punctuation.
                        Text("•")
                            .font(.system(size: 14))
                            .foregroundStyle(JcTheme.muted)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(.system(size: 14))
                            .foregroundStyle(JcTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// A watcher's output. Deliberately a CARD where an utterance is bare text: §7.1
/// asks for insights to be visually distinct, and the transcript is the thing that
/// should read as a conversation.
struct LiveInsightCard: View {
    let insight: LiveInsight

    private var symbol: String {
        switch insight.kind.lowercased() {
        case "factcheck", "fact_check": return "checkmark.seal"
        case "translate", "translation": return "globe"
        default: return "sparkles"
        }
    }

    private var title: String {
        switch insight.kind.lowercased() {
        // "Verdict", not "Fact-check": this card is the RESULT of a tap, and a
        // bare "Fact-check" heading reads as the app announcing that it went
        // and checked something by itself.
        case "factcheck", "fact_check": return "Fact-check verdict"
        case "translate", "translation": return "Translation"
        case "monitor": return "Jarvis"
        default: return insight.kind.capitalized
        }
    }

    var body: some View {
        GlassCard(padding: 13,
                  fill: JcTheme.accent.opacity(0.08),
                  borderColor: JcTheme.accent.opacity(0.28)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    JcIcon(symbol, size: 13).foregroundStyle(JcTheme.accent)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(JcTheme.accent)
                    Spacer(minLength: 0)
                }
                Text(insight.text)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(insight.text)")
    }
}

/// Wrapped so the views do not import UIKit and the copy action is testable.
enum LivePasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}


// MARK: - On-device translation

extension View {
    /// Give `translator` a session whenever it has a language pair to work on.
    ///
    /// Behind an availability check and a `canImport` so the app still builds
    /// and runs where the framework does not exist — there the translator
    /// reports everything as unavailable and the server does the work, which is
    /// what happened before any of this.
    @ViewBuilder
    func liveTranslation(_ translator: LiveTranslator) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            self.modifier(LiveTranslationModifier(translator: translator))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct LiveTranslationModifier: ViewModifier {
    let translator: LiveTranslator

    func body(content: Content) -> some View {
        content.translationTask(session) { session in
            await translator.run(session)
        }
    }

    /// The framework's own configuration, derived from the plain pair the
    /// translator asked for. Nil means there is nothing waiting, and SwiftUI
    /// then holds no session at all.
    private var session: TranslationSession.Configuration? {
        guard let want = translator.configuration else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: want.sourceCode),
            target: Locale.Language(identifier: want.targetCode))
    }
}
#endif


/// Turning a BCP-47 tag into something a person reads.
enum LiveLanguageName {
    /// "Spanish → English", or nil when the source is unknown.
    ///
    /// The target is left implicit: it is the language the reader is reading,
    /// and naming it on every card is noise. What they cannot tell by looking
    /// is where the line CAME from.
    static func trip(from source: String) -> String? {
        guard let name = name(source) else { return nil }
        return "from \(name)"
    }

    /// "es-419" → "Spanish". Nil for an empty or unrecognisable tag, so the
    /// caller can show nothing rather than a raw code.
    static func name(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let localized = Locale.current.localizedString(forIdentifier: trimmed)
            ?? Locale.current.localizedString(
                forLanguageCode: String(trimmed.split(separator: "-")[0]))
        guard let localized, !localized.isEmpty, localized != trimmed else {
            return nil
        }
        return localized
    }
}


/// Re-pins the transcript to its newest line once the user's own scroll comes
/// to rest at the end, and opens it there.
///
/// Decided when the scroll SETTLES, not on every offset change: while text is
/// arriving the content grows under a still finger, and an offset rule would
/// flip the pin back and forth mid-drag. iOS 17 keeps the drag rule and the
/// arrow button only.
private struct LiveFollowsBottom: ViewModifier {
    @Binding var pinned: Bool
    @State private var atBottom = true

    /// How close to the end still counts as "at the end".
    private static let slack: CGFloat = 48

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let shownTo = geometry.contentOffset.y + geometry.containerSize.height
                        - geometry.contentInsets.bottom
                    return shownTo >= geometry.contentSize.height - Self.slack
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { pinned = atBottom }
                }
        } else {
            content
        }
    }
}
