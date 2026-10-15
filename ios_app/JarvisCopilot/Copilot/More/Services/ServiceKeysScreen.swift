import SwiftUI

/// Which keys a `ServiceKeysScreen` edits.
enum ServiceKeysScope: Hashable {
    /// One service's key and settings, or every service's (nil).
    case services(String?)
    /// The exchange accounts the portfolio reads.
    case exchanges
}

/// Keys and settings for the services (and the portfolio's exchanges). Keys
/// stay on the server: a saved key is never shown here, only that one is
/// saved, and only what you type (or remove) is sent.
struct ServiceKeysScreen: View {
    let scope: ServiceKeysScope
    var store: ServicesStore = .shared

    private var title: String {
        switch scope {
        case .exchanges: return "Exchange keys"
        case .services(let id?):
            return store.config?.services.first { $0.id == id }?.displayName ?? "Keys"
        case .services(nil): return "Service keys"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(intro)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.horizontal, 4)
                if let config = store.config {
                    cards(config)
                } else if let error = store.configError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                } else {
                    ProgressView().tint(JcTheme.muted).frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.loadConfig() }
        .jcScreen(title)
        .task { await store.loadConfig() }
        .moreToast(Binding(get: { store.toast }, set: { store.toast = $0 }), seconds: 3.5)
    }

    private var intro: String {
        switch scope {
        case .exchanges:
            return "Read-only API keys for the exchanges whose balances the portfolio shows. They stay on your Jarvis server; saved keys are never shown again."
        case .services:
            return "Keys stay on your Jarvis server. A saved key is never shown again: type a new one to replace it."
        }
    }

    @ViewBuilder private func cards(_ config: ServicesConfig) -> some View {
        switch scope {
        case .exchanges:
            ForEach(config.exchanges) { entry in
                KeysCard(title: entry.displayName, configured: entry.configured,
                         fields: entry.secrets, settings: []) { draft in
                    await store.saveExchange(entry, draft: draft)
                }
            }
        case .services(let id):
            let entries = config.services.filter { id == nil || $0.id == id }
            if entries.isEmpty {
                Text("This service isn't on the server.")
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
            }
            ForEach(entries) { entry in
                KeysCard(title: entry.displayName, configured: entry.configured,
                         fields: entry.secrets, settings: entry.settings) { draft in
                    await store.saveService(entry, draft: draft)
                }
            }
        }
    }
}

/// One service's (or exchange's) keys and settings, with its own Save.
struct KeysCard: View {
    let title: String
    let configured: Bool
    let fields: [ServiceSecretField]
    let settings: [ServiceSetting]
    let save: (KeysDraft) async -> Bool

    @State private var draft = KeysDraft()
    @State private var busy = false

    private var changed: Bool {
        !draft.secretsPayload(fields: fields).isEmpty || !draft.settingsPayload(settings).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(configured ? JcTheme.success : JcTheme.muted).frame(width: 7, height: 7)
                    Text(configured ? "Connected" : "Not set up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(configured ? JcTheme.success : JcTheme.muted)
                }
            }
            ForEach(fields) { field in secretRow(field) }
            ForEach(settings) { setting in settingRow(setting) }
            HStack {
                Spacer()
                Button {
                    busy = true
                    Task {
                        if await save(draft) { draft = KeysDraft() }
                        busy = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini).tint(JcTheme.accent) }
                        Text("Save")
                    }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(!changed || busy)
            }
        }
        .padding(14)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
    }

    private func secretRow(_ field: ServiceSecretField) -> some View {
        let removing = draft.removed.contains(field.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                Spacer()
                if field.hasKey {
                    if removing {
                        Text("Removed on Save")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(JcTheme.danger)
                        Button("Keep") { draft.removed.remove(field.name) }
                            .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                    } else {
                        Text("Saved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(JcTheme.success)
                        Button("Remove") {
                            draft.removed.insert(field.name)
                            draft.typed[field.name] = nil
                        }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                    }
                }
            }
            SecureField(field.hasKey ? "Saved. Type a new one to replace it" : "Paste it here",
                        text: Binding(get: { draft.typed[field.name] ?? "" },
                                      set: { draft.typed[field.name] = $0 }))
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .disabled(removing)
                .padding(10)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(field.label)
        }
    }

    private func settingRow(_ setting: ServiceSetting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setting.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JcTheme.muted)
            TextField(setting.placeholder,
                      text: Binding(get: { draft.settings[setting.key] ?? setting.text },
                                    set: { draft.settings[setting.key] = $0 }),
                      axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(setting.key == "url" ? .URL : setting.key == "from" ? .emailAddress : .default)
                .padding(10)
                .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if case .list = setting.value {
                Text("Names, comma-separated. Empty watches all of them.")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }
}
