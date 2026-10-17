import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Finished agent turns in Spotlight: search a prompt, an answer or a project
/// and land on that session. Items expire after 30 days. Off with the
/// "Spotlight" switch in the Agents History screen.
@MainActor
enum AgentsSpotlight {
    static let domain = "agent-turns"
    static let enabledKey = "jc.agents.spotlight"
    private static var indexed: Set<String> = []

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue {
                indexed = []
                CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
            }
        }
    }

    static func identifier(key: String, startedAt: Date) -> String {
        "agent-turn|\(Int(startedAt.timeIntervalSince1970))|\(key)"
    }

    /// The engine key a Spotlight item opens, or nil when it isn't one of ours.
    static func key(from identifier: String) -> String? {
        let parts = identifier.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "agent-turn", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    static func index(_ sessions: [AgentConv]) {
        guard enabled else { return }
        var items: [CSSearchableItem] = []
        for s in sessions {
            guard let turn = s.turnSummary, let started = turn.startedAt, turn.endedAt != nil,
                  !turn.prompt.isEmpty || !turn.final.isEmpty else { continue }
            let id = identifier(key: s.ckey, startedAt: started)
            guard !indexed.contains(id) else { continue }
            indexed.insert(id)
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = "\(s.project) — \(s.agentName)"
            attrs.contentDescription = [turn.prompt, turn.final].filter { !$0.isEmpty }.joined(separator: "\n")
            attrs.keywords = [s.project, s.agentName, "agent", "coding"]
            let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attrs)
            item.expirationDate = Date().addingTimeInterval(30 * 86_400)
            items.append(item)
        }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }
}

/// The decisions taken on this phone (Allow, Deny, Always, answers), newest
/// first, for the History screen. Kept on the phone only.
struct AgentDecisionRecord: Codable, Identifiable, Equatable {
    var at: Date
    var project: String
    var agent: String
    var summary: String
    var decision: String
    var id: String { "\(at.timeIntervalSince1970)|\(summary)" }
}

enum AgentsDecisionLog {
    static let key = "jc.agents.decisions"
    static let limit = 200

    static func all(defaults: UserDefaults = .standard) -> [AgentDecisionRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AgentDecisionRecord].self, from: data)) ?? []
    }

    static func record(_ request: AgentRequest, decision: String, at: Date = Date(),
                       defaults: UserDefaults = .standard) {
        var list = all(defaults: defaults)
        list.insert(AgentDecisionRecord(at: at, project: request.project, agent: request.agentName,
                                        summary: request.kind == .question
                                            ? (request.questions.first?.question ?? "Question")
                                            : (request.command.isEmpty ? request.summary : request.command),
                                        decision: decision), at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
