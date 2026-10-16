import Foundation

/// The expanded island's tabs.
enum IslandTab: String, CaseIterable, Identifiable {
    case agents, chat, music
    /// Talking to Jarvis: the voice panel in the island (the orb in the ear,
    /// "Hey Jarvis", the tab row's orb). Not one of the tab buttons.
    case voice
    var id: String { rawValue }

    /// The tab row's buttons.
    static var tabBar: [IslandTab] { allCases.filter { $0 != .voice } }

    /// What opening the island by a click on the notch shows: only the orb
    /// opens Voice, so from Voice it's the last other tab.
    static func forIslandClick(current: IslandTab, last: IslandTab) -> IslandTab {
        current == .voice ? (last == .voice ? .agents : last) : current
    }

    var icon: String {
        switch self {
        case .agents: return "terminal"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .music: return "music.note"
        case .voice: return "waveform"
        }
    }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .chat: return "Chat"
        case .music: return "Music"
        case .voice: return "Voice"
        }
    }

    /// The expanded height of every tab but Agents (which sizes to its sessions)
    /// and Music (to its rows; expandedHeight passes the real inset).
    var height: CGFloat {
        switch self {
        case .agents: return 500
        case .chat: return 480
        case .music: return IslandLayout.musicHeight(topInset: 40)   // sized to its rows
        case .voice: return IslandLayout.voiceHeight(topInset: 40)   // the panel under the tab row
        }
    }
}
