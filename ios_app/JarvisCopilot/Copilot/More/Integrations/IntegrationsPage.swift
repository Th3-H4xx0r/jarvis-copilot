import SwiftUI

/// Integrations — what Jarvis keeps for you and what it runs on your behalf.
///
/// This is where the Tasks (cron) screen went. A schedule no longer stands on
/// its own: it belongs to an integration, next to the data that integration
/// keeps in the registry and the skills written for it.
///
/// The tab owns its stack, and the stack is type-erased: the screens inside push
/// their own value types (an `Integration`, then an `IntegrationDataRoute`), and
/// a typed path can only hold one of them — a link carrying anything else
/// silently does nothing.
struct IntegrationsPage: View {
    @State private var store: IntegrationsStore
    @State private var path = NavigationPath()
    @State private var settingUp = false

    init(store: IntegrationsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { IntegrationsStore() })
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 10) {
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
                    GlassIconButton(symbol: "plus", size: 34, iconSize: 16) { settingUp = true }
                }
            }
            .navigationDestination(for: Integration.self) { integration in
                IntegrationDetailView(integration: integration, store: store)
            }
            .navigationDestination(for: IntegrationDataRoute.self) { route in
                switch route {
                case .records(let id, let collection):
                    IntegrationRecordsView(integrationID: id, collection: collection, store: store)
                case .document(let id, let key):
                    IntegrationDocumentView(integrationID: id, key: key, store: store)
                case .skill(_, let name):
                    IntegrationSkillView(name: name)
                }
            }
        }
        .task { if !store.hasLoaded { store.load() } }
        .onTabVisibilityChange(.integrations) { visible in
            if !visible { store.onDisappear() }
            else if store.hasLoaded { Task { await store.refresh() } }
        }
        .moreToast($store.toast)
        .fullScreenCover(isPresented: $settingUp) {
            IntegrationSetupSheet { await store.refresh() }
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
            CenteredMessage(text: "No integrations yet. Tap + and tell Jarvis what to track.")
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
                        .font(JcText.label)
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if integration.isPaused {
                        StatusPill(integration.status.uppercased(),
                                   color: JcTheme.muted, dense: true)
                    }
                    JcIcon("chevron.right", size: 11)
                        .foregroundStyle(JcTheme.muted.opacity(0.6))
                        .fixedSize()
                }
                if !integration.summary.isEmpty {
                    Text(integration.summary)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 8)
                }
                Text(integration.subtitle)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted.opacity(0.8))
                    .padding(.top, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
