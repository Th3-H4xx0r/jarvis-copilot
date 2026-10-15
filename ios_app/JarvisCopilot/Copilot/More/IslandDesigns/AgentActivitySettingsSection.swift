import SwiftUI

/// "Live Activities for agents": one Lock Screen / Dynamic Island activity per
/// coding agent, wearing its logo. ONE setting on the server (the Code Master
/// settings' `agent_live`), shown in two places: Code Master settings (saved with
/// that page's Save button) and the Dynamic Island tab (saved on each change).
struct AgentActivitySettingsSection: View {
    @Bindable var store: CodeMasterSettingsStore
    /// Save each change at once (the Dynamic Island tab, which has no Save button).
    var saveOnChange = false

    /// One idle window, for `JcSegmented`.
    struct IdleChoice: Hashable, Identifiable {
        let minutes: Int
        var id: Int { minutes }
        static let all = AgentLiveSettings.idleChoices.map(IdleChoice.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Live Activities for agents")
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: binding(\.enabled)) {
                        Text("A Live Activity for each coding agent")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                    }
                    .tint(JcTheme.accent)
                    Text("On the Lock Screen and in the Dynamic Island, with the agent's logo, "
                         + "the session that needs you first and how many others are running. "
                         + "It starts on its own, even while Jarvis is closed.")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.agentLive.enabled {
                GlassQuietLabel("Agents").padding(.top, 22)
                GlassGroup {
                    ForEach(Array(AgentBrand.all.enumerated()), id: \.element) { index, agent in
                        AgentToggleRow(agent: agent,
                                       on: agentBinding(agent),
                                       last: index == AgentBrand.all.count - 1)
                    }
                }

                GlassQuietLabel("End after idle for").padding(.top, 22)
                JcSegmented(items: IdleChoice.all, selection: idleBinding,
                            label: { "\($0.minutes) min" })
                Text("An agent's activity also ends once all its sessions have.")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                GlassQuietLabel("On the Lock Screen").padding(.top, 22)
                GlassCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: binding(\.actions)) {
                            Text("Show Allow / Deny on the Lock Screen")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                        }
                        .tint(JcTheme.accent)
                        Text("For a request Jarvis is holding (Remote approvals on). "
                             + "Allow asks you to unlock first.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.agentLive.enabled)
    }

    // MARK: Bindings

    private func binding(_ key: WritableKeyPath<AgentLiveSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.agentLive[keyPath: key] },
                set: { store.agentLive[keyPath: key] = $0; changed() })
    }

    private func agentBinding(_ agent: String) -> Binding<Bool> {
        Binding(get: { store.agentLive.isOn(agent) },
                set: { store.agentLive.set(agent, $0); changed() })
    }

    private var idleBinding: Binding<IdleChoice> {
        Binding(get: { IdleChoice(minutes: store.agentLive.idleMinutes) },
                set: { store.agentLive.idleMinutes = $0.minutes; changed() })
    }

    private func changed() {
        guard saveOnChange else { return }
        Task { await store.saveAgentLive() }
    }
}

/// One agent: its logo, what it covers, and its switch.
struct AgentToggleRow: View {
    let agent: String
    @Binding var on: Bool
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentLogoMark(agent: agent, size: 36)
                    .opacity(on ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentBrand.title(for: agent))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    Text(AgentBrand.covers(agent))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $on)
                    .labelsHidden()
                    .tint(JcTheme.accent)
                    .accessibilityLabel("\(AgentBrand.title(for: agent)) Live Activity")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !last {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 62)
            }
        }
    }
}

/// The Dynamic Island tab's copy of the section: it loads the shared settings
/// itself and saves each change as it's made.
struct AgentActivitiesIslandSection: View {
    @State private var store: CodeMasterSettingsStore

    init(store: CodeMasterSettingsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            CodeMasterSettingsStore()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.loading {
                GlassQuietLabel("Live Activities for agents")
                ProgressView().tint(JcTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                AgentActivitySettingsSection(store: store, saveOnChange: true)
                if let error = store.error {
                    CodingInlineError(message: error).padding(.top, 14)
                }
            }
        }
        .task {
            if store.onSaved == nil { store.onSaved = LiveActivityCoordinator.agentSettingsChanged }
            if store.loading { await store.load() }
        }
    }
}
