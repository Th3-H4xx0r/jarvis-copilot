import SwiftUI

/// Integrations — what Jarvis keeps for you and what it runs on your behalf.
///
/// This is where the Tasks (cron) screen went. A schedule no longer stands on
/// its own: it belongs to an integration, next to the data that integration
/// keeps in the registry and the skills written for it. Tapping one opens
/// `IntegrationDetailView`; tapping a schedule there opens the same cron detail
/// sheet the Tasks screen used, so run/pause/edit are unchanged.
struct IntegrationsPage: View {
    @State private var store: IntegrationsStore
    @State private var creating = false
    @State private var newName = ""

    init(store: IntegrationsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { IntegrationsStore() })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .loadErrorBanner(store.errorMessage, hasContent: !store.integrations.isEmpty)
        .jcScreen("Integrations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "plus", size: 34, iconSize: 16) {
                    newName = ""
                    creating = true
                }
            }
        }
        .task { if !store.hasLoaded { store.load() } }
        .onTabVisibilityChange(.more) { visible in
            if !visible { store.onDisappear() }
            else if store.hasLoaded { Task { await store.refresh() } }
        }
        .moreToast($store.toast)
        .navigationDestination(for: Integration.self) { integration in
            IntegrationDetailView(integration: integration, store: store)
        }
        .navigationDestination(for: IntegrationDataRoute.self) { route in
            switch route {
            case .records(_, let collection):
                IntegrationRecordsView(collection: collection, store: store)
            case .document(_, let key):
                IntegrationDocumentView(key: key, store: store)
            }
        }
        .alert("New integration", isPresented: $creating) {
            TextField("Gym Sessions", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.create(name: newName) } }
        } message: {
            Text("It gets its own data, schedules and skills.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage, store.integrations.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 100)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if store.isEmpty {
            CenteredMessage(text: "No integrations yet. Ask Jarvis for one, or add it here.")
                .padding(.top, 100)
        } else {
            ForEach(store.integrations) { integration in
                NavigationLink(value: integration) {
                    IntegrationCard(integration: integration)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One integration in the list: what it is, and how much of it there is.
struct IntegrationCard: View {
    let integration: Integration

    var body: some View {
        GlassCard(padding: 14,
                  borderColor: integration.isPaused ? JcTheme.muted.opacity(0.35) : nil) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    JcIcon(IntegrationIcon.symbol(for: integration.icon), size: 16)
                        .foregroundStyle(JcTheme.accent)
                        .fixedSize()
                    Text(integration.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if integration.isPaused {
                        StatusPill(integration.status.uppercased(),
                                   color: JcTheme.muted, dense: true)
                    }
                }
                if !integration.summary.isEmpty {
                    Text(integration.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 8)
                }
                Text(integration.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted.opacity(0.8))
                    .padding(.top, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
