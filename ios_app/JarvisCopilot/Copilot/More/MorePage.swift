import SwiftUI

/// The More tab: a grid of launchers, ported from `pages/more_page.dart`.
///
/// Every tile pushes through `destination(for:)` — the one place that maps a
/// `MoreDestination` to a screen. To land a real page, add its file in the area
/// that owns it and change that case.
struct MorePage: View {
    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    /// The grid owns its stack. `path:` exists so a test (or a future deep link)
    /// can open a screen without a tap — SwiftUI's tiles are not `UIView`s, so
    /// there is nothing for a test to activate.
    @State private var ownPath: [MoreDestination] = []
    private let injectedPath: Binding<[MoreDestination]>?

    init(path: Binding<[MoreDestination]>? = nil) {
        self.injectedPath = path
    }

    private var path: Binding<[MoreDestination]> { injectedPath ?? $ownPath }

    var body: some View {
        NavigationStack(path: path) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(MoreDestination.grid) { item in
                        NavigationLink(value: item) { Tile(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationDestination(for: MoreDestination.self) { destination(for: $0) }
            .jcScreen("More")
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
        case .tasks:
            TasksPage()
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
        case .moshi:
            MoshiPage()
        }
    }

    /// One launcher: a frosted square with a circular glyph and a two-line label.
    /// `blur: false` — a grid of blurred cards is the one place the material
    /// actually costs frames.
    /// A launcher in the Voice page's register: flat, quiet, one icon and a
    /// label — no chip inside a card.
    private struct Tile: View {
        let item: MoreDestination

        var body: some View {
            VStack(spacing: 9) {
                Image(systemName: item.symbol)
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
