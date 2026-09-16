import SwiftUI

/// The plan card in chat.
///
/// Asking Jarvis to track something doesn't create anything. It calls
/// `integration_plan_propose`, and that call draws here instead of as a tool
/// row: what the integration is for, the schedules it wants, the data it will
/// keep, the skills it would write — then Create or Cancel. Nothing exists on
/// the server until Create.
///
/// The layout is fixed here, not by the model. The model supplies text for
/// these slots and nothing else, which is what keeps every card looking like
/// the app instead of like whatever the model emitted that turn.
struct IntegrationPlanCard: View {
    let planID: String
    var api: IntegrationsAPI = IntegrationsAPI()

    @State private var plan: IntegrationPlan?
    @State private var errorMessage: String?
    @State private var working = false

    var body: some View {
        GlassCard(padding: 0, borderColor: JcTheme.accent.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 0) {
                if let plan {
                    header(plan)
                    body(plan)
                    footer(plan)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.danger)
                        .padding(14)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if plan == nil { await load() } }
    }

    // MARK: Slots

    private func header(_ plan: IntegrationPlan) -> some View {
        HStack(spacing: 9) {
            JcIcon(IntegrationIcon.symbol(for: plan.icon), size: 15)
                .foregroundStyle(JcTheme.accent)
                .fixedSize()
            Text(plan.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(plan.statusLabel)
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(JcTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(JcTheme.accent.opacity(0.14)))
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private func body(_ plan: IntegrationPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.schedules.isEmpty {
                slot("Schedules") {
                    ForEach(plan.schedules) { schedule in
                        PlanRow(name: schedule.name, trailing: schedule.when, note: schedule.purpose)
                    }
                }
            }
            if !plan.collections.isEmpty {
                slot("Data") {
                    ForEach(plan.collections) { item in
                        PlanRow(name: item.name, trailing: "", note: item.summary)
                    }
                }
            }
            if !plan.skills.isEmpty {
                slot("Skills") {
                    ForEach(plan.skills) { item in
                        PlanRow(name: item.name, trailing: "", note: item.summary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private func slot<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.9)
                .foregroundStyle(JcTheme.muted.opacity(0.85))
            content()
        }
    }

    @ViewBuilder
    private func footer(_ plan: IntegrationPlan) -> some View {
        HStack(spacing: 10) {
            Text(footerNote(plan))
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(2)
            Spacer(minLength: 0)
            if plan.isPending {
                Button("Cancel") { Task { await decide(approve: false) } }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
                Button("Create") { Task { await decide(approve: true) } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .disabled(working)
        .opacity(working ? 0.5 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.04))
    }

    private func footerNote(_ plan: IntegrationPlan) -> String {
        if let errorMessage { return errorMessage }
        switch plan.status {
        case "approved":  return "Running as \(plan.spaceID)."
        case "cancelled": return "Nothing was created."
        default:          return working ? "Working…" : "Nothing exists until you say so."
        }
    }

    // MARK: Actions

    private func load(clearingError: Bool = true) async {
        do {
            plan = try await api.plan(planID)
            if clearingError { errorMessage = nil }
        } catch {
            errorMessage = apiErrorMessage(error)
        }
    }

    private func decide(approve: Bool) async {
        working = true
        var failure: String?
        do {
            if approve { try await api.approvePlan(planID) } else { try await api.cancelPlan(planID) }
        } catch {
            failure = apiErrorMessage(error)
        }
        // Redraw from the server either way — the plan may have been decided on
        // another device — but a failure the user has to know about survives it.
        await load(clearingError: failure == nil)
        errorMessage = failure
        working = false
    }

    /// The plan's id, out of the tool call that proposed it.
    ///
    /// The tool returns `{"ok": true, "plan": {"id": "…"`, so the id is near the
    /// front and survives however much of the result the chat kept.
    static func planID(in tool: ToolInvocation) -> String? {
        guard tool.name == "integration_plan_propose" else { return nil }
        for text in [tool.result, tool.preview].compactMap({ $0 }) {
            if let id = extractID(text) { return id }
        }
        return nil
    }

    private static func extractID(_ text: String) -> String? {
        guard let planRange = text.range(of: "\"plan\"") else { return nil }
        let tail = text[planRange.upperBound...]
        guard let idRange = tail.range(of: "\"id\"") else { return nil }
        let afterID = tail[idRange.upperBound...]
        // "id" : "abc123" — take what is inside the next pair of quotes.
        guard let open = afterID.firstIndex(of: "\""),
              case let valueStart = afterID.index(after: open),
              let close = afterID[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(afterID[valueStart..<close])
        return value.isEmpty ? nil : value
    }
}

private struct PlanRow: View {
    let name: String
    let trailing: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}
