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

    var body: some View {
        VStack(spacing: 0) {
            statusLine
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

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
        .overlay(alignment: .bottom) {
            if !store.error.isEmpty { errorToast(store.error) }
        }
    }

    // MARK: - Status

    /// One line: what the recorder is doing, and how much audio is kept. Both,
    /// because "recording" without a storage figure is how an ambient recorder
    /// quietly fills a disk.
    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .opacity(store.capturing && !store.interrupted ? 1 : 0.55)
            Text(store.statusText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(JcTheme.text.opacity(0.9))
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
            Text(store.storageText)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
            Spacer(minLength: 6)
            Button { showSettings = true } label: {
                JcIcon("gear", size: 15).foregroundStyle(JcTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Live settings")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.white.opacity(0.045), in: Capsule())
        .overlay(alignment: .bottomLeading) { sttNotice }
    }

    /// §8 requires a fall back to the server lane to be STATED, not silent.
    @ViewBuilder
    private var sttNotice: some View {
        if !store.sttNotice.isEmpty {
            Text(store.sttNotice)
                .font(.system(size: 11))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(2)
                .offset(y: 26)
        }
    }

    private var statusColor: Color {
        if store.halt != nil { return JcTheme.danger }
        if store.interrupted { return JcTheme.amber }
        if !store.capturing { return JcTheme.muted }
        return store.connected ? JcTheme.accent : JcTheme.amber
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
        if store.rows.isEmpty {
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

            Button { showSpeakers = true } label: {
                JcIcon("person.2", size: 17)
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 48, height: 48)
                    .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voices")

            Button { showStorage = true } label: {
                JcIcon("internaldrive", size: 17)
                    .foregroundStyle(JcTheme.accent)
                    .frame(width: 48, height: 48)
                    .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Storage")
        }
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

    /// A confirmed voice gets the accent; an unconfirmed one stays neutral, so the
    /// colour carries the confidence rather than only the word beside it.
    private var chipTint: Color {
        segment.labelState == .confirmed ? JcTheme.accent : JcTheme.muted
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
