import Foundation

/// Everything the More grid can open, ported from `pages/more_page.dart`'s tile
/// list (plus the two launchers that live in the Flutter Settings page,
/// Dynamic Island designs and Photon).
///
/// The grid iterates `grid`; `MorePage` turns a case into a screen in a single
/// `switch`. A second-wave agent landing, say, `TodosPage` changes exactly one
/// line there and nothing else in the shell.
enum MoreDestination: String, CaseIterable, Identifiable, Hashable {
    case tasks
    case kanban
    case memory
    case codeMemory
    case longTermMemory
    case workspaces
    case profiles
    case todos
    case insights
    case selfImprovement
    case serverLogs
    case islandDesigns
    case photon
    case settings

    var id: String { rawValue }

    /// Tile order, matching the Flutter grid.
    static let grid: [MoreDestination] = allCases

    var title: String {
        switch self {
        case .tasks:           return "Tasks (cron)"
        case .kanban:          return "Kanban"
        case .memory:          return "Memory"
        case .codeMemory:      return "Code memory"
        case .longTermMemory:  return "Long-term memory"
        case .workspaces:      return "Workspaces"
        case .profiles:        return "Profiles"
        case .todos:           return "Todos"
        case .insights:        return "Insights"
        case .selfImprovement: return "Learning"
        case .serverLogs:      return "Server logs"
        case .islandDesigns:   return "Dynamic Island"
        case .photon:          return "Photon"
        case .settings:        return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .tasks:           return "clock"
        case .kanban:          return "rectangle.split.3x1"
        case .memory:          return "memorychip"
        case .codeMemory:      return "point.3.connected.trianglepath.dotted"
        case .longTermMemory:  return "brain"
        case .workspaces:      return "folder"
        case .profiles:        return "person"
        case .todos:           return "checklist"
        case .insights:        return "chart.line.uptrend.xyaxis"
        case .selfImprovement: return "sparkles"
        case .serverLogs:      return "doc.text"
        case .islandDesigns:   return "rectangle.on.rectangle"
        case .photon:          return "bubble.left.and.bubble.right"
        case .settings:        return "gearshape"
        }
    }
}
