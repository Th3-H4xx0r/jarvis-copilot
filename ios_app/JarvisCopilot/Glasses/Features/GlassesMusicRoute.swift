import Foundation

enum GlassesMusicRoute: Equatable {
    case resume, rejectShortcut

    static func resolve(skill: String, args: [String: Any], connected: Bool, chatOpen: Bool) -> Self? {
        guard connected || chatOpen else { return nil }
        if skill == "media_control" {
            let action = (args["action"] as? String ?? "").lowercased()
            if action == "play" || (action == "toggle" && chatOpen) { return .resume }
        }
        if skill == "run_shortcut" {
            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == "jc play pause", chatOpen { return .resume }
            if ["jc play pause", "jc next track", "jc previous track"].contains(name) { return .rejectShortcut }
        }
        return nil
    }
}
