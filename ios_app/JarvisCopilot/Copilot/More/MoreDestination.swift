import Foundation

/// Everything the More grid can open, in tile order. `MorePage` turns a case
/// into a screen in a single `switch`.
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
    case appleWatch
    case settings

    var id: String { rawValue }

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
        case .appleWatch:      return "Apple Watch"
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
        case .appleWatch:      return "applewatch"
        case .settings:        return "gearshape"
        }
    }
}
