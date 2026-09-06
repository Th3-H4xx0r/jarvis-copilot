import Foundation
import Observation

/// One line of `InvokeRunner.log`, made identifiable and display-ready.
struct SkillInvokeLogRow: Identifiable, Equatable {
    var skill: String
    var argsSummary: String
    var outcome: String
    var failed: Bool
    var at: Date
    var id: String

    /// "3:07 PM" — the log is a within-session trace, so the time is enough.
    var timeLabel: String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: at)
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d:%02d %@", hour12, c.minute ?? 0, c.second ?? 0,
                      hour24 < 12 ? "AM" : "PM")
    }
}

/// View state for the Skills tab.
///
/// `SkillRegistry` and `InvokeRunner` predate Observation and are plain
/// `@MainActor` classes, so nothing there publishes changes. This model is the
/// observable mirror: it snapshots both on `reload()` and re-snapshots after
/// every mutation, which is also what makes the screen testable against an
/// injected registry rather than the process-wide singletons.
@Observable
@MainActor
final class SkillsPageModel {
    private let registry: SkillRegistry
    private let runner: InvokeRunner

    /// Search text; the list filters against name AND description.
    var query = ""

    private(set) var items: [SkillListItem] = []
    private(set) var log: [SkillInvokeLogRow] = []
    /// Mirrors `InvokeRunner.paused`, which has no change notification.
    private(set) var paused = false

    init(registry: SkillRegistry? = nil, runner: InvokeRunner? = nil) {
        self.registry = registry ?? .shared
        self.runner = runner ?? .shared
    }

    // MARK: Derived

    var filtered: [SkillListItem] { SkillsGrouping.filter(items, query: query) }
    var sections: [SkillSection] { SkillsGrouping.sections(filtered) }
    var summary: String { SkillsGrouping.summary(items) }
    var isEmpty: Bool { items.isEmpty }
    var hasResults: Bool { !filtered.isEmpty }

    // MARK: Snapshot

    func reload() {
        items = registry.all.map {
            SkillListItem(name: $0.name,
                          detail: $0.description,
                          requiresForeground: $0.requiresForeground,
                          enabled: registry.isEnabled($0.name))
        }
        paused = runner.paused
        reloadLog()
    }

    func reloadLog() {
        log = runner.log.enumerated().map { index, entry in
            SkillInvokeLogRow(
                skill: entry.skill,
                argsSummary: entry.args.isEmpty ? "" : SkillArgsForm.prettyJSON(entry.args),
                outcome: entry.error ?? (entry.result.map(SkillArgsForm.prettyJSON) ?? "ok"),
                failed: entry.error != nil,
                at: entry.at,
                // The log is newest-first and grows at the head, so the index
                // alone isn't stable — pair it with the timestamp.
                id: "\(entry.skill)#\(entry.at.timeIntervalSince1970)#\(index)")
        }
    }

    // MARK: Mutations

    /// Toggle a skill. A disabled skill is neither advertised in the bridge
    /// manifest nor dispatchable, so this is a real ACL, not a display filter.
    func setEnabled(_ enabled: Bool, for name: String) {
        registry.setEnabled(enabled, for: name)
        reload()
    }

    func setPaused(_ value: Bool) {
        runner.paused = value
        paused = value
    }

    // MARK: Test run

    func schema(for name: String) -> [String: Any] {
        registry.find(name)?.inputSchema ?? [:]
    }

    func fields(for name: String) -> [SkillArgField] {
        SkillArgsForm.fields(from: schema(for: name))
    }

    /// Run a skill locally, exactly as an incoming invoke would — same runner,
    /// so the pause flag, the ACL and the foreground deferral all apply and what
    /// you see here is what the server would get.
    func run(_ name: String, arguments: [String: Any]) async -> String {
        let outcome = await runner.run(name, arguments)
        reloadLog()
        if let error = outcome.error { return "error: \(error)" }
        return SkillArgsForm.prettyJSON(outcome.result ?? [:])
    }
}
