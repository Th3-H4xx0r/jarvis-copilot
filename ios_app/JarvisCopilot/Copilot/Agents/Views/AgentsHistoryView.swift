import SwiftUI

/// What happened lately: the decisions you took from this phone, and the
/// last week's finished turns (from the server), grouped by day.
struct AgentsHistoryView: View {
    @State private var turns: [AgentsAPI.TurnRecord] = []
    @State private var decisions: [AgentDecisionRecord] = []
    @State private var error: String?
    @State private var spotlight = AgentsSpotlight.enabled

    var body: some View {
        ScrollView {
            JcPageColumn {
                JcSectionLabel("Spotlight", first: true)
                JcCard(padding: 0) {
                    JcRow(symbol: "magnifyingglass", title: "Show finished turns in Spotlight", last: true) {
                        Toggle("", isOn: $spotlight).labelsHidden().tint(JcTheme.accent)
                    }
                }
                .onChange(of: spotlight) { _, on in AgentsSpotlight.enabled = on }

                JcSectionLabel("Your decisions")
                JcCard(padding: 0) {
                    if decisions.isEmpty {
                        Text("Nothing decided from this phone yet")
                            .font(.system(size: 15))
                            .foregroundStyle(JcTheme.muted)
                            .padding(JcUnified.cardPadding)
                    }
                    let shown = Array(decisions.prefix(50))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, d in
                        decisionRow(d)
                        if index < shown.count - 1 { JcRowSeparator() }
                    }
                }

                ForEach(byDay, id: \.day) { group in
                    JcSectionLabel(group.day.formatted(date: .complete, time: .omitted))
                    JcCard(padding: 0) {
                        ForEach(Array(group.turns.enumerated()), id: \.element.id) { index, t in
                            JcRow(title: t.project,
                                  subtitle: "\(t.agent) · \(minutes(t)) · \(t.files) file\(t.files == 1 ? "" : "s") · \(t.commands) command\(t.commands == 1 ? "" : "s")",
                                  last: index == group.turns.count - 1) {
                                Text("+\(t.added) −\(t.removed)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(JcTheme.muted)
                            }
                        }
                    }
                }
                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.top, 16)
                }
            }
        }
        .jcPageChrome("History")
        .task {
            decisions = AgentsDecisionLog.all()
            do { turns = try await AgentsAPI().history() } catch { self.error = apiErrorMessage(error) }
        }
    }

    private func decisionRow(_ d: AgentDecisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(d.decision.capitalized)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(d.decision == "deny" ? JcTheme.danger : JcTheme.success)
                Text("\(d.agent) · \(d.project)")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(d.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            Text(d.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(JcTheme.text.opacity(0.85))
                .lineLimit(2)
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
    }

    private var byDay: [(day: Date, turns: [AgentsAPI.TurnRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: turns) { cal.startOfDay(for: $0.endedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    private func minutes(_ t: AgentsAPI.TurnRecord) -> String {
        let m = max(0, Int(t.endedAt.timeIntervalSince(t.startedAt) / 60))
        return m < 1 ? "<1 min" : "\(m) min"
    }
}
