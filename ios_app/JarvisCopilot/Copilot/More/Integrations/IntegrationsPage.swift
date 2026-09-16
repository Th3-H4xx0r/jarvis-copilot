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
            // An inset-grouped List: system row metrics, separators, disclosure
            // indicators and swipe actions, rather than a stack of cards that has
            // to reimplement all four and gets the tap targets wrong doing it.
            List {
                content
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, integrationTapTarget)
            .refreshable { await store.refresh() }
            .loadErrorBanner(store.errorMessage, hasContent: !store.integrations.isEmpty)
            .overlay { emptyState }
            .jcScreen("Integrations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingUp = true } label: {
                        JcIcon("plus", size: 16)
                            .frame(width: integrationTapTarget, height: integrationTapTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("New integration")
                }
            }
            .navigationDestination(for: Integration.self) { integration in
                IntegrationDetailView(integration: integration, store: store)
            }
            .navigationDestination(for: IntegrationDataRoute.self) { route in
                switch route {
                case .data(let id):
                    IntegrationDataListView(integrationID: id, store: store)
                case .skills(let id):
                    IntegrationSkillsListView(integrationID: id, store: store)
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
        Section {
            ForEach(store.integrations) { integration in
                NavigationLink(value: integration) {
                    IntegrationRowLabel(integration: integration)
                }
                .listRowBackground(JcTheme.surface)
                .swipeActions(edge: .trailing) {
                    Button {
                        Task { await store.togglePause(integration) }
                    } label: {
                        Label(integration.isPaused ? "Resume" : "Pause",
                              systemImage: integration.isPaused ? "play.fill" : "pause.fill")
                    }
                    .tint(integration.isPaused ? JcTheme.accent : JcTheme.muted)
                }
            }
        } footer: {
            if !store.integrations.isEmpty {
                Text("Each one owns its own schedules, what it stores, and the skills written for it.")
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }

    /// Loading, failure and emptiness sit over the list rather than inside it, so
    /// none of them inherits a row's inset and separators.
    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.integrations.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
        } else if !store.hasLoaded {
            ProgressView()
        } else if store.isEmpty {
            ContentUnavailableView {
                Label("No Integrations", jcIcon: "folder")
            } description: {
                Text("Tell Jarvis what you want tracked and it builds one: the schedules that do the work, somewhere to keep the results, and the skills to read them back.")
            } actions: {
                Button("New Integration") { settingUp = true }
                    .buttonStyle(.borderedProminent)
                    .tint(JcTheme.accent)
            }
        }
    }
}

/// One integration in the list. Leads with whether it runs, because that is the
/// question the list is scanned for; the counts follow.
struct IntegrationRowLabel: View {
    let integration: Integration

    var body: some View {
        HStack(spacing: 12) {
            JcIcon(IntegrationIcon.symbol(for: integration.icon), size: 17)
                .foregroundStyle(integration.isPaused ? JcTheme.muted : JcTheme.accent)
                .fixedSize()
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(IntegrationType.body)
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(status)
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    /// "2 schedules running · 18 records", or "Paused" when nothing of it runs —
    /// state as a word, never as a colour on its own.
    private var status: String {
        if integration.isPaused { return "Paused · \(integration.subtitle)" }
        let running = integration.enabledScheduleCount
        if running == 0 && integration.scheduleCount == 0 {
            return integration.summary.isEmpty ? integration.subtitle : integration.summary
        }
        if running == 0 { return "All schedules paused · \(integration.subtitle)" }
        return integration.subtitle
    }
}
