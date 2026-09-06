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
                ProgressView().tint(JcTheme.primaryBlue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .jcScreen("Code Master settings")
        .task { if store.loading { await store.load() } }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Notifications")
                Text("Which coding events notify you, and on which channels.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 14)
                ForEach(CodeMasterSettingsStore.events, id: \.key) { event in
                    eventCard(event).padding(.bottom, 12)
                }

                GlassQuietLabel("Usage rings").padding(.top, 12)
                GlassCard(padding: 14, blur: false) {
                    Toggle(isOn: Binding(get: { store.usageDisplay },
                                         set: { store.usageDisplay = $0 })) {
                        Text("Show the 5-hour / weekly account-usage rings")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                    }
                    .tint(JcTheme.primaryBlue)
                }

                GlassQuietLabel("Remote approvals").padding(.top, 22)
                GlassCard(padding: 14, blur: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { store.remoteApprovals },
                                             set: { store.remoteApprovals = $0 })) {
                            Text("Approve tool permissions from your phone "
                                 + "(relays prompts to the mobile app)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                        }
                        .tint(JcTheme.primaryBlue)
                        Text("Turn on when you’re away from the terminal. "
                             + "While off, sessions prompt locally as usual.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                    }
                }

                if let error = store.error {
                    CodingInlineError(message: error).padding(.top, 18)
                }
                if store.savedAt != nil && store.error == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                        Text("Code Master settings saved").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(JcTheme.success)
                    .padding(.top, 18)
                }

                GradientButton(store.saving ? "Saving…" : "Save settings",
                               symbol: "checkmark", busy: store.saving, full: true,
                               action: { Task { await store.save() } })
                    .padding(.top, 26)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    private func eventCard(_ event: (key: String, label: String)) -> some View {
        GlassCard(padding: 14, blur: false) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .padding(.bottom, 4)
                ForEach(CodeMasterSettingsStore.channels, id: \.key) { channel in
                    Toggle(isOn: Binding(
                        get: { store.value(event: event.key, channel: channel.key) },
                        set: { store.set(event: event.key, channel: channel.key, $0) })) {
                            HStack(spacing: 12) {
                                Image(systemName: channel.symbol)
                                    .font(.system(size: 15))
                                    .foregroundStyle(JcTheme.muted)
                                    .frame(width: 20)
                                Text(channel.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(JcTheme.text)
                            }
                        }
                        .tint(JcTheme.primaryBlue)
                        .padding(.vertical, 2)
                }
            }
        }
    }
}
