import Observation
import SwiftUI

/// Opens a Power integration's page.
struct PowerRoute: Hashable { let id: String }

/// The Power section at the top of the Integrations tab: built-in features, each with
/// its card, a Power tag and its switch.
struct PowerSection: View {
    @Bindable var power: PowerState
    var onToast: (String) -> Void

    var body: some View {
        if !power.rows.isEmpty {
            JcSectionLabel("Power", first: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(power.rows) { row in
                PowerCardView(row: row, power: power, onToast: onToast)
            }
        }
    }
}

/// One Power integration on the tab: header (icon, name, Power tag, status, switch)
/// and, when it has one, its card UI underneath.
struct PowerCardView: View {
    let row: PowerRow
    @Bindable var power: PowerState
    var onToast: (String) -> Void
    @State private var ui: IntegrationUIStore?

    var body: some View {
        JcCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    NavigationLink(value: PowerRoute(id: row.id)) { header }.buttonStyle(.plain)
                    PowerSwitch(row: row, power: power, onToast: onToast)
                }
                if let error = row.error { IntegrationUIErrorLine(text: error) }
                if row.enabled {
                    if let native = PowerNative.card(row) {
                        native
                    } else if let ui, let root = ui.root {
                        IntegrationUIRenderer.view(root, store: ui)
                    }
                }
            }
        }
        .opacity(row.enabled ? 1 : 0.7)
        .task(id: row.enabled) {
            guard row.hasCard, row.enabled else { return }
            let store = ui ?? IntegrationUIStore(integrationID: row.id, presentation: .card,
                                                 basePath: PowerAPI.prefix)
            ui = store
            await store.load()
        }
        .onChange(of: ui?.toast) { _, message in
            guard let message else { return }
            onToast(message)
            ui?.toast = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            JcIconSquare(symbol: row.icon)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    StatusPill("Power", color: JcTheme.muted, dense: true)
                }
                Text(PowerCopy.subtitle(row, pending: power.pending.contains(row.id)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

enum PowerCopy {
    static func subtitle(_ row: PowerRow, pending: Bool) -> String {
        if pending { return "Waiting for Face ID" }
        if !row.enabled { return "Off" }
        return row.statusLine.isEmpty ? row.summary : row.statusLine
    }
}

/// The switch. A protected integration's switch-off waits for Face ID (the approval
/// card comes up on this phone); a refusal ("Disarm the alarm first") is a toast.
struct PowerSwitch: View {
    let row: PowerRow
    @Bindable var power: PowerState
    var onToast: (String) -> Void
    @State private var working = false

    var body: some View {
        Toggle("", isOn: Binding(
            get: { row.enabled },
            set: { on in flip(on) }))
            .labelsHidden()
            .disabled(working || power.pending.contains(row.id))
            .accessibilityLabel("\(row.name) on")
    }

    private func flip(_ on: Bool) {
        working = true
        Task {
            let result = await power.set(row.id, enabled: on)
            working = false
            if case .failed(let message) = result { onToast(message) }
        }
    }
}

/// A Power integration's page: its switch and status, its own page UI, links to the
/// screens it already has, its settings, and its schedules/skills/data.
struct PowerPage: View {
    let id: String
    @Bindable var power: PowerState
    @State private var ui: IntegrationUIStore?
    @State private var toast: String?
    @Environment(AppRouter.self) private var router: AppRouter?

    private var row: PowerRow? { power.row(id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let row {
                    header(row)
                    if row.enabled { pageUI(row) }
                    links(row)
                    PowerSettingsForm(row: row, power: power, onToast: { toast = $0 })
                    data(row)
                } else {
                    JcLoader().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await power.refresh()
            await ui?.load()
        }
        .jcPageChrome(row?.name ?? "Power")
        .moreToast($toast)
        .task(id: row?.enabled) {
            guard let row, row.hasPage, row.enabled else { return }
            let store = ui ?? IntegrationUIStore(integrationID: row.id, presentation: .page,
                                                 basePath: PowerAPI.prefix)
            ui = store
            await store.load()
        }
    }

    private func header(_ row: PowerRow) -> some View {
        JcCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    JcIconSquare(symbol: row.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.enabled ? "On" : "Off")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                            StatusPill("Power", color: JcTheme.muted, dense: true)
                            if row.protected {
                                StatusPill("Face ID", color: JcTheme.muted, dense: true)
                            }
                        }
                        Text(PowerCopy.subtitle(row, pending: power.pending.contains(row.id)))
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Spacer(minLength: 0)
                    PowerSwitch(row: row, power: power, onToast: { toast = $0 })
                }
                Text(row.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = row.error { IntegrationUIErrorLine(text: error) }
            }
        }
    }

    @ViewBuilder
    private func pageUI(_ row: PowerRow) -> some View {
        if let native = PowerNative.page(row) {
            native
        } else if let ui {
            IntegrationUIPageSection(store: ui)
        }
    }

    @ViewBuilder
    private func links(_ row: PowerRow) -> some View {
        let shown = row.enabled ? row.iosLinks : []
        if !shown.isEmpty {
            JcSectionLabel("Open")
            GlassGroup {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, link in
                    if PowerLinkDestination.isTab(link.target) {
                        GlassRow(symbol: row.icon, title: link.label, last: index == shown.count - 1) {
                            router?.selectedTab = .health
                        }
                    } else {
                        NavigationLink { PowerLinkDestination.view(for: link.target) } label: {
                            GlassRow(symbol: row.icon, title: link.label, last: index == shown.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func data(_ row: PowerRow) -> some View {
        Group {
            JcSectionLabel("Schedules and data")
            GlassGroup {
                NavigationLink(value: Integration(json: ["id": row.space, "name": row.name,
                                                         "icon": "bolt", "description": row.summary])) {
                    GlassRow(symbol: "clock", title: "Schedules, skills and data",
                             subtitle: "What it keeps and runs", last: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A Power integration's settings, drawn from what the server declares. Each field
/// saves on its own; a secret only ever shows whether it's set.
struct PowerSettingsForm: View {
    let row: PowerRow
    @Bindable var power: PowerState
    var onToast: (String) -> Void
    @State private var drafts: [String: String] = [:]

    var body: some View {
        if let native = PowerNative.settings(row) {
            JcSectionLabel("Settings")
            native
        } else if !row.settingsSchema.isEmpty {
            JcSectionLabel("Settings")
            JcCard {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(row.settingsSchema) { setting in field(setting) }
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ s: PowerSetting) -> some View {
        let value = row.settings[s.key] ?? .none
        VStack(alignment: .leading, spacing: 6) {
            switch s.kind {
            case .toggle:
                Toggle(s.label, isOn: Binding<Bool>(
                    get: { if case .bool(let b) = value { return b } else { return false } },
                    set: { save(s.key, $0) }))
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.text)
            case .picker:
                Text(s.label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                Picker(s.label, selection: Binding<String>(
                    get: { if case .text(let t) = value { return t } else { return "" } },
                    set: { save(s.key, $0) })) {
                    ForEach(s.options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
            case .number:
                HStack {
                    Text(s.label).font(.system(size: 15)).foregroundStyle(JcTheme.text)
                    Spacer()
                    TextField("", text: draft(s, value), onCommit: { commitNumber(s) })
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                    if !s.unit.isEmpty { Text(s.unit).foregroundStyle(JcTheme.muted) }
                }
            case .text:
                Text(s.label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                TextField(s.label, text: draft(s, value), onCommit: { save(s.key, drafts[s.key] ?? "") })
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .secret:
                HStack {
                    Text(s.label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                    Spacer()
                    Text(PowerSettingsForm.secretLabel(value)).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
                SecureField("Replace", text: Binding(get: { drafts[s.key] ?? "" },
                                                     set: { drafts[s.key] = $0 }),
                            onCommit: {
                                let text = drafts[s.key] ?? ""
                                guard !text.isEmpty else { return }
                                save(s.key, text)
                                drafts[s.key] = ""
                            })
            }
            if !s.help.isEmpty {
                Text(s.help).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
        }
    }

    static func secretLabel(_ value: PowerValue) -> String {
        if case .secretSet(true) = value { return "Set" }
        return "Not set"
    }

    private func draft(_ s: PowerSetting, _ value: PowerValue) -> Binding<String> {
        Binding(get: {
            if let d = drafts[s.key] { return d }
            switch value {
            case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
            case .text(let t): return t
            default: return ""
            }
        }, set: { drafts[s.key] = $0 })
    }

    private func commitNumber(_ s: PowerSetting) {
        guard let text = drafts[s.key], let number = Double(text) else { return }
        save(s.key, number == number.rounded() ? Int(number) as Any : number as Any)
    }

    private func save(_ key: String, _ value: Any) {
        Task {
            let result = await power.setSettings(row.id, [key: value])
            switch result {
            case .failed(let message): onToast(message)
            case .pending: onToast("Approve the change with Face ID")
            case .done: drafts[key] = nil
            }
        }
    }
}
