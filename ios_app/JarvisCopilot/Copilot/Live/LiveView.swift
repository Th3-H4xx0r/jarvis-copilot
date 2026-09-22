import Combine
import SwiftUI
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

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if store.rows.isEmpty && store.partialText.isEmpty && store.wrapUp == nil {
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
                                               onFactCheck: { Task { await store.factCheck(segment) } },
                                               onTranslate: { Task { await store.translate(segment) } },
                                               onName: {
                                                   nameDraft = segment.speakerName ?? ""
                                                   naming = segment
                                               })
                            case .insight(let insight):
                                LiveInsightCard(insight: insight)
                            }
                        }
                        // The words being spoken right now, from this phone's
                        // own recogniser. Always last, because it is by
                        // definition the newest thing said — and it disappears
                        // the moment its committed row arrives.
                        if !store.partialText.isEmpty {
                            LiveProvisionalRow(text: store.partialText,
                                               startMs: store.partialStartMs)
                                .id(Self.partialAnchor)
                                .transition(.opacity)
                        }
                        // The wrap-up closes the transcript, after everything it
                        // summarises.
                        if let wrap = store.wrapUp {
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
                .onChange(of: store.rows.count) { _, _ in
                    guard pinnedToBottom else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                // Following the LIVE words too, and unanimated: the text grows
                // word by word, and a 0.22s ease on every one of them reads as
                // the transcript sliding about rather than as speech arriving.
                .onChange(of: store.partialText) { _, text in
                    guard pinnedToBottom, !text.isEmpty else { return }
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                // Dragging is taken as "I am reading"; the newest row stops pulling
                // the view away from what the user is looking at.
                .simultaneousGesture(DragGesture().onChanged { value in
                    if value.translation.height > 12 { pinnedToBottom = false }
                })
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

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if store.capturing { await store.stop() } else { await store.start() }
                }
            } label: {
                HStack(spacing: 8) {
                    JcIcon(store.capturing ? "stop.fill" : "record.circle", size: 16)
                    Text(store.capturing ? "Stop" : "Record")
                        .font(JcText.body.weight(.semibold))
                }
                .foregroundStyle(store.capturing ? JcTheme.danger : JcTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.halt != nil)
            .opacity(store.halt == nil ? 1 : 0.5)

            secondary("person.2", "Voices") { showSpeakers = true }
            secondary("internaldrive", "Storage") { showStorage = true }
            secondary("gear", "Settings") { showSettings = true }
        }
    }

    /// A glyph on its own was unguessable — a drive for Storage, two people for
    /// Voices — so each says its word. `buttons.md › Best practices` wants a
    /// control both reachable and "instantly recognizable".
    private func secondary(_ symbol: String, _ title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                JcIcon(symbol, size: 16)
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(JcTheme.text.opacity(0.82))
            .frame(width: 62, height: 52)
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
    let onFactCheck: () -> Void
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
                factCheckButton
            }

            Text(segment.text)
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let translation = segment.translation {
                HStack(alignment: .top, spacing: 6) {
                    JcIcon("globe", size: 11).foregroundStyle(JcTheme.muted)
                    Text(translation)
                        .font(.system(size: 13.5))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Fact-check", jcIcon: "checkmark.seal", action: onFactCheck)
            Button("Translate", jcIcon: "globe", action: onTranslate)
            Button("Copy", jcIcon: "doc.on.doc") {
                LivePasteboard.copy(segment.text)
            }
            Button("Name this voice", jcIcon: "person.crop.circle", action: onName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker) at \(LiveFormat.stamp(ms: segment.startMs)): \(segment.text)")
    }

    /// Fact-check, on the row, where it can be found.
    ///
    /// It used to exist only in the long-press menu, and the honest report was
    /// "not seeing any buttons for fact check or anything like that" — a hidden
    /// control is not a control. So this one is visible on every line and says
    /// its word, for the reason the Storage and Voices buttons on this screen
    /// say theirs: a glyph alone was unguessable.
    ///
    /// Quiet, though: `glassFill` and `muted`, never the accent. A transcript is
    /// meant to read as a conversation, and a bright button per line would make
    /// the affordance louder than the thing it is about. The rest of the actions
    /// stay in the menu.
    private var factCheckButton: some View {
        Button(action: onFactCheck) {
            HStack(spacing: 4) {
                JcIcon("checkmark.seal", size: 11)
                Text("Fact-check")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(JcTheme.muted)
            .padding(.horizontal, 8)
            .frame(height: Self.affordanceHeight)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            // The drawn capsule is 26pt so a row stays a row; the TAP is 44pt,
            // per `buttons.md`. The negative padding gives the layout its 26pt
            // back after `contentShape` has already taken the bigger rectangle,
            // so the extra reach lands in the 12pt gutter between rows — where
            // nothing else is tappable.
            .padding(.vertical, (Self.minimumTarget - Self.affordanceHeight) / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -(Self.minimumTarget - Self.affordanceHeight) / 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fact-check this line")
        .accessibilityHint("Asks Jarvis to check what was said and adds its verdict to the transcript.")
    }

    /// Drawn height of the row's affordance, and the hit region it must reach.
    static let affordanceHeight: CGFloat = 26
    static let minimumTarget: CGFloat = 44

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
        case "factcheck", "fact_check": return "Fact-check"
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
