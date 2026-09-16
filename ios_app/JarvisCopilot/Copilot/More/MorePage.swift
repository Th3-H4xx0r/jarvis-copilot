import SwiftUI

/// The More tab: a grid of launchers.
///
/// Every tile pushes through `destination(for:)` — the one place that maps a
/// `MoreDestination` to a screen. To land a real page, add its file in the area
/// that owns it and change that case.
struct MorePage: View {
    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    /// The grid owns its stack. `initialPath` lets a test open a screen without a
    /// tap — SwiftUI's tiles are not `UIView`s, so there is nothing to activate.
    ///
    /// Type-erased, not `[MoreDestination]`: a screen inside the stack pushes its
    /// own value types (Integrations pushes an `Integration`, then an
    /// `IntegrationDataRoute`), and a typed array can only hold its one type — a
    /// link carrying anything else silently does nothing at all.
    @State private var path: NavigationPath
    /// Optional so tests without the shell still build the page.
    @Environment(AppRouter.self) private var router: AppRouter?

    init(initialPath: [MoreDestination] = []) {
        _path = State(initialValue: NavigationPath(initialPath))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(MoreDestination.allCases) { item in
                        NavigationLink(value: item) { Tile(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationDestination(for: MoreDestination.self) { destination(for: $0) }
            .jcScreen("More")
        }
        // A card elsewhere (the Chat dashboard) asked for a screen: open it on
        // top of the grid, so Back lands on More.
        .onChange(of: router?.screenRequestGeneration, initial: true) { _, _ in
            if let requested = router?.consumeMoreDestination() {
                path = NavigationPath([requested])
            }
        }
    }

    /// The single routing table. `switch` (not a dictionary) so the compiler
    /// refuses to build if a destination is ever left unrouted.
    @ViewBuilder
    private func destination(for item: MoreDestination) -> some View {
        switch item {
        case .settings:
            SettingsPage()
        case .todos:
            TodosPage()
        case .memory:
            MemoryPage()
        case .longTermMemory:
            LongTermMemoryPage()
        case .codeMemory:
            CodeMemoryPage()
        case .kanban:
            KanbanPage()
        case .integrations:
            IntegrationsPage()
        case .workspaces:
            WorkspacesPage()
        case .profiles:
            ProfilesPage()
        case .insights:
            InsightsPage()
        case .selfImprovement:
            SelfImprovementPage()
        case .serverLogs:
            ServerLogsPage()
        case .islandDesigns:
            IslandDesignsPage()
        case .photon:
            PhotonSetupPage()
        case .appleWatch:
            WatchPage()
        }
    }

    /// A launcher in the Voice page's register: flat, quiet, one icon and a
    /// label — no chip inside a card.
    private struct Tile: View {
        let item: MoreDestination

        var body: some View {
            VStack(spacing: 9) {
                JcIcon(item.symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(JcTheme.cyan.opacity(0.9))
                    .frame(height: 26)
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.text.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
