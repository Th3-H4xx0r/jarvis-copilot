import SwiftUI

/// What happened lately: the decisions you took from this phone, and the
/// last week's finished turns (from the server), grouped by day.
struct AgentsHistoryView: View {
    @State private var turns: [AgentsAPI.TurnRecord] = []
    @State private var decisions: [AgentDecisionRecord] = []
    @State private var error: String?
    @State private var spotlight = AgentsSpotlight.enabled

    var body: some View {
        List {
            Section {
                Toggle("Show finished turns in Spotlight", isOn: $spotlight)
                    .onChange(of: spotlight) { _, on in AgentsSpotlight.enabled = on }
            }
            Section("Your decisions") {
                if decisions.isEmpty {
                    Text("Nothing decided from this phone yet.").foregroundStyle(JcTheme.muted)
                }
                ForEach(decisions.prefix(50)) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.decision.capitalized).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(d.decision == "deny" ? JcTheme.danger : JcTheme.success)
                            Text("\(d.agent) · \(d.project)").font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                            Spacer()
                            Text(d.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                        }
                        Text(d.summary).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                    }
                }
            }
            ForEach(byDay, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.turns) { t in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.project).font(.system(size: 14, weight: .semibold))
                                Text("\(t.agent) · \(minutes(t)) · \(t.files) file\(t.files == 1 ? "" : "s") · \(t.commands) command\(t.commands == 1 ? "" : "s")")
                                    .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                            }
                            Spacer()
                            Text("+\(t.added) −\(t.removed)").font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(JcTheme.muted)
                        }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(JcTheme.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("History")
        .task {
            decisions = AgentsDecisionLog.all()
            do { turns = try await AgentsAPI().history() } catch { self.error = apiErrorMessage(error) }
        }
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
