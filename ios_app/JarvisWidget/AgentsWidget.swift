import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets for the coding agents: the one that
/// needs you (or is working), or the short list. Reads the values the app's
/// WidgetDataHub wrote to the App Group; the app reloads it when they change.
struct AgentsEntry: TimelineEntry {
    let date: Date
    let values: [String: JCJSON]

    func text(_ key: String) -> String {
        if case .string(let s)? = values[key] { return s }
        return ""
    }

    func number(_ key: String) -> Int? {
        if case .number(let n)? = values[key] { return Int(n) }
        return nil
    }

    var waiting: Bool {
        if case .bool(let b)? = values["coding.lead_waiting"] { return b }
        return false
    }

    var list: [(project: String, agent: String, state: String, step: String)] {
        guard case .array(let items)? = values["coding.agents"] else { return [] }
        return items.compactMap { item in
            guard case .object(let o) = item else { return nil }
            func s(_ k: String) -> String { if case .string(let v)? = o[k] { return v }; return "" }
            return (s("project"), s("agent"), s("state"), s("step"))
        }
    }
}

struct AgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: Date(), values: ["coding.lead_agent": .string("Claude Code"),
                                           "coding.lead_project": .string("jarvis"),
                                           "coding.lead_state": .string("Working"),
                                           "coding.lead_step": .string("Bash: npm test")])
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        completion(AgentsEntry(date: Date(), values: WidgetDataFile.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        let entry = AgentsEntry(date: Date(), values: WidgetDataFile.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

private func agentColor(_ state: String) -> Color {
    switch state.lowercased() {
    case "approval", "question", "needs approval", "has a question": return Color(red: 0.98, green: 0.75, blue: 0.14)
    case "working", "thinking": return Color(red: 0.20, green: 0.83, blue: 0.60)
    case "error", "failed": return .red
    default: return .gray
    }
}

struct AgentsWidgetView: View {
    let entry: AgentsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.text("coding.lead_agent").isEmpty ? "No agents"
                 : "\(entry.text("coding.lead_project")): \(entry.text("coding.lead_state"))")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.waiting ? "exclamationmark.bubble.fill" : "terminal")
                    .font(.system(size: 18, weight: .semibold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text("coding.lead_project").isEmpty ? "Agents" : entry.text("coding.lead_project"))
                    .font(.headline).lineLimit(1)
                Text(entry.text("coding.lead_state").isEmpty ? "Nothing running" : entry.text("coding.lead_state"))
                    .font(.caption).lineLimit(1)
                if !entry.text("coding.lead_step").isEmpty {
                    Text(entry.text("coding.lead_step")).font(.caption2).lineLimit(1)
                }
            }
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(agentColor(entry.text("coding.lead_state"))).frame(width: 8, height: 8)
                Text(entry.text("coding.lead_agent").isEmpty ? "Agents" : entry.text("coding.lead_agent"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(entry.text("coding.lead_project").isEmpty ? "All quiet" : entry.text("coding.lead_project"))
                .font(.system(size: 17, weight: .bold)).lineLimit(1)
            Text(entry.text("coding.lead_state")).font(.system(size: 13, weight: .medium))
                .foregroundStyle(agentColor(entry.text("coding.lead_state")))
            Text(entry.text("coding.lead_step")).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if let five = entry.number("coding.claude_5h") {
                Text("Claude \(five)% · 5h").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agents").font(.system(size: 13, weight: .bold))
                Spacer()
                if let five = entry.number("coding.claude_5h") {
                    Text("5h \(five)%").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let week = entry.number("coding.claude_week") {
                    Text("Week \(week)%").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if entry.list.isEmpty {
                Text("Nothing running").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.list.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Circle().fill(agentColor(row.state)).frame(width: 7, height: 7)
                    Text(row.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(row.step).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct AgentsWidget: Widget {
    let kind = "AgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgentsProvider()) { entry in
            AgentsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "jarviscopilot://agents"))
        }
        .configurationDisplayName("Agents")
        .description("Your coding agents: the one that needs you, or what's working.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular,
                            .accessoryRectangular, .accessoryInline])
    }
}

/// Control Center: open the agent that needs you.
@available(iOS 18.0, *)
struct AgentsControl: ControlWidget {
    static let kind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget1.AgentsControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "jarviscopilot://agents")!)) {
                Label("Agents", systemImage: "terminal")
            }
        }
        .displayName("Coding agents")
        .description("Opens the agent that needs you.")
    }
}
