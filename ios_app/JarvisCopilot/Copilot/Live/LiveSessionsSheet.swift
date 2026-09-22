import SwiftUI

/// Which Live conversation you are looking at.
///
/// Live-scoped on purpose. The Voice screen's session picker and model chip
/// govern VOICE turns, and showing them here would offer to change something
/// that has no effect on a recording. This lists `GET /api/live/sessions` — the
/// conversations Live itself recorded — and nothing else.
///
/// A past conversation opens READ-ONLY. The server will adopt an ended session
/// if a client asks to append to it, but "reopen a finished recording by
/// tapping it in a list" is not a thing the user asked for and not a thing this
/// screen should do by accident; looking back is looking back.
struct LiveSessionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// A plain `let`: `LiveStore` is `@Observable`, so SwiftUI tracks what this
    /// body reads through the reference itself.
    let store: LiveStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    current
                    past
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
            .jcScreen("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(JcText.body.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
            }
        }
        .task { await store.loadSessions() }
    }

    // MARK: - The one you are in

    private var current: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel(store.readOnly ? "Looking back" : "Now")
            GlassGroup {
                if store.readOnly {
                    GlassRow(symbol: "arrow.uturn.left",
                             title: "Back to the live conversation",
                             subtitle: "Leave this recording and return to recording.",
                             subtitleLineLimit: 2,
                             action: {
                                 store.stopViewing()
                                 dismiss()
                             }) { EmptyView() }
                } else {
                    GlassRow(symbol: "dot.radiowaves.left.and.right",
                             title: store.liveSessionID.isEmpty
                                ? "No conversation yet"
                                : "This conversation",
                             subtitle: store.liveSessionID.isEmpty
                                ? "Tap Record and one begins."
                                : "Stopping and starting continues it.",
                             subtitleLineLimit: 2) { EmptyView() }
                }
                // Starting fresh is the user's call; WHEN a long one rolls over
                // on its own is the server's.
                GlassRow(symbol: "square.and.pencil",
                         title: "Start a new conversation",
                         subtitle: store.capturing
                            ? "Stop recording first."
                            : "The next recording begins a separate session.",
                         subtitleLineLimit: 2,
                         last: true,
                         action: store.capturing ? nil : {
                             store.startFreshSession()
                             dismiss()
                         }) { EmptyView() }
                    .opacity(store.capturing ? 0.5 : 1)
            }
        }
    }

    // MARK: - The ones before it

    @ViewBuilder
    private var past: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Earlier")
            if store.sessions.isEmpty {
                Text(store.loadingSessions
                     ? "Loading…"
                     : "Nothing recorded yet. Conversations appear here once you have "
                     + "recorded one.")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
            } else {
                GlassGroup {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        GlassRow(symbol: session.isRecording
                                    ? "dot.radiowaves.left.and.right" : "text.bubble",
                                 title: session.displayTitle,
                                 subtitle: session.subtitle,
                                 subtitleLineLimit: 2,
                                 last: index == store.sessions.count - 1,
                                 action: { open(session) }) {
                            if session.id == store.viewingSessionID
                                || (!store.readOnly && session.id == store.liveSessionID) {
                                JcIcon("checkmark", size: 14).foregroundStyle(JcTheme.accent)
                            }
                        }
                    }
                }
                Text("Opening one shows its transcript to read. Recording always continues "
                   + "the live conversation.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }

    private func open(_ session: LiveSessionSummary) {
        Task {
            await store.view(session: session)
            dismiss()
        }
    }
}
