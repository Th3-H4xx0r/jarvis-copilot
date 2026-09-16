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

/// One integration in the list, in the card the rest of the app uses: a round
/// icon tile, a name, and one line under it. Leads with whether it runs, because
/// that is what the list is scanned for.
struct IntegrationCard: View {
    let integration: Integration

    private var accent: Color { integration.isPaused ? JcTheme.muted : JcTheme.accent }

    var body: some View {
        GlassCard(padding: 12, fill: JcTheme.surface,
                  borderColor: integration.isPaused ? JcTheme.muted.opacity(0.28) : JcTheme.glassBorder) {
            HStack(spacing: 12) {
                JcIcon(IntegrationIcon.symbol(for: integration.icon))
                    .font(.system(size: 19))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(integration.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if integration.isPaused {
                            StatusPill("PAUSED", color: JcTheme.muted, dense: true)
                        } else if integration.scheduleCount > 0, integration.enabledScheduleCount == 0 {
                            StatusPill("ALL OFF", color: JcTheme.muted, dense: true)
                        }
                        Spacer(minLength: 0)
                    }
                    // One line for every row, always the same line — the prose
                    // description lives on the detail screen, where it has room.
                    Text(integration.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                JcIcon("chevron.right", size: 11)
                    .foregroundStyle(JcTheme.muted.opacity(0.6))
                    .fixedSize()
            }
            .frame(minHeight: integrationTapTarget)
        }
    }
}
