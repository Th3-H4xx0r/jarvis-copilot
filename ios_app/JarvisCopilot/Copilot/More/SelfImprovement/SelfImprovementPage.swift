import SwiftUI

/// The "Learning" screen, ported from `pages/self_improvement_page.dart`.
///
/// What the agent has been teaching itself — skills auto-created or patched,
/// memory updated, and the attempts it rejected — newest first, straight from
/// the server's `self_improvement.log`.
struct SelfImprovementPage: View {
    @State private var store: SelfImprovementStore

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: SelfImprovementStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { SelfImprovementStore() })
    }

    var body: some View {
        content
            .loadErrorBanner(store.errorMessage, hasContent: !store.events.isEmpty)
            .jcScreen("Learning")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.load() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(store.isLoading)
                        .accessibilityLabel("Reload")
                }
            }
            .task { if !store.hasLoaded { store.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage, store.events.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .frame(maxHeight: .infinity)
        } else if store.isEmpty {
            ScrollView {
                CenteredMessage(text: store.emptyText).padding(.top, 100)
            }
            .refreshable { await store.refresh() }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.events) { event in
                        SelfImprovementCard(event: event)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh() }
        }
    }
}

/// One event: a LEARNED / REVIEWED / REJECTED / FAILED badge with its origin,
/// the change text, and how long ago it happened.
struct SelfImprovementCard: View {
    let event: SelfImprovementEvent

    var body: some View {
        GlassCard(padding: 14, blur: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusPill(event.label, color: Color(tone: event.tone), dense: true)
                    if !event.origin.isEmpty {
                        Text(event.origin)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                let stamp = event.tsLabel()
                if !stamp.isEmpty {
                    Text(stamp).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
