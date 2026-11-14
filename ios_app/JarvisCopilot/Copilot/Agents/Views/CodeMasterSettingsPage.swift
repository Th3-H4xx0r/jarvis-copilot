import SwiftUI

/// Global "Code Master settings" — which coding events notify you on which
/// channels, whether the account-usage rings show, and whether tool-permission
/// prompts relay to the phone for remote approval. Port of
/// `pages/code_master_settings_page.dart`.
///
/// Rendered as one card per EVENT with the four channel switches inside: a true
/// 3×4 table is too cramped on a phone. The store owns the load/merge/save rules
/// (`CodeMasterSettingsStore`).
struct CodeMasterSettingsPage: View {
    @State private var store: CodeMasterSettingsStore

    init(store: CodeMasterSettingsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            CodeMasterSettingsStore()
        })
    }

    var body: some View {
        Group {
            if store.loading {
                JcLoader().foregroundStyle(JcTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .jcPageChrome("Code Master settings")
        .task {
            if store.onSaved == nil { store.onSaved = LiveActivityCoordinator.agentSettingsChanged }
            if store.loading { await store.load() }
        }
    }

    private var form: some View {
        ScrollView {
            JcPageColumn {
                JcSectionLabel("Notifications", first: true)
                Text("Which coding events notify you, and on which channels")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.bottom, 10)
                VStack(spacing: 12) {
                    ForEach(CodeMasterSettingsStore.events, id: \.key) { event in
                        eventCard(event)
                    }
                }

                JcSectionLabel("Usage rings")
                JcCard(padding: 0) {
                    toggleRow("chart.pie", "Show the 5-hour and weekly usage rings", nil,
                              Binding(get: { store.usageDisplay }, set: { store.usageDisplay = $0 }))
                }

                JcSectionLabel("Remote approvals")
                JcCard(padding: 0) {
                    toggleRow("hand.raised", "Approve tool permissions from your phone",
                              "Relays prompts to the phone. Turn on when you’re away from the terminal; "
                              + "while off, sessions prompt locally as usual",
                              Binding(get: { store.remoteApprovals }, set: { store.remoteApprovals = $0 }))
                }

                JcSectionLabel("Instructions from the phone")
                JcCard(padding: 0) {
                    toggleRow("paperplane", "Send a session its next instruction from the Agents tab",
                              "Typed into the session’s terminal on your Mac (VS Code with the Jarvis extension, "
                              + "or iTerm). A session that’s mid-turn gets it when the turn ends",
                              Binding(get: { store.remoteInstructions }, set: { store.remoteInstructions = $0 }))
                }

                // One Live Activity per coding agent — the same setting the
                // Dynamic Island tab edits.
                AgentActivitySettingsSection(store: store).padding(.top, 22)

                if let error = store.error {
                    CodingInlineError(message: error).padding(.top, 18)
                }
                if store.savedAt != nil && store.error == nil {
                    HStack(spacing: 6) {
                        JcIcon("checkmark.circle.fill", size: 13)
                        Text("Code Master settings saved").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(JcTheme.success)
                    .padding(.top, 18)
                }

                GradientButton(store.saving ? "Saving…" : "Save settings",
                               symbol: "checkmark", busy: store.saving, full: true,
                               action: { Task { await store.save() } })
                    .padding(.top, 26)
            }
        }
    }

    private func toggleRow(_ symbol: String, _ title: String, _ subtitle: String?,
                           _ isOn: Binding<Bool>, last: Bool = true) -> some View {
        JcRow(symbol: symbol, title: title, subtitle: subtitle, subtitleLines: 4, last: last) {
            Toggle(title, isOn: isOn).labelsHidden().tint(JcTheme.accent)
        }
    }

    private func eventCard(_ event: (key: String, label: String)) -> some View {
        JcCard(padding: 0) {
            Text(event.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
                .padding(.horizontal, JcUnified.cardPadding)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(Array(store.channels.enumerated()), id: \.element.key) { index, channel in
                toggleRow(channel.symbol, channel.label, nil,
                          Binding(get: { store.value(event: event.key, channel: channel.key) },
                                  set: { store.set(event: event.key, channel: channel.key, $0) }),
                          last: index == store.channels.count - 1)
            }
        }
    }
}

/// The inline red strip for a recoverable error inside a sheet or a page
/// (Code Master settings, the island's agent settings, the Agents sheets).
struct CodingInlineError: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            JcIcon("exclamationmark.circle", size: 15).foregroundStyle(JcTheme.danger)
            Text(message).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(JcTheme.danger.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.30), lineWidth: 1))
    }
}
