import Observation
import SwiftUI

/// The Mac settings window's Integrations section: the Power integrations drawn
/// natively (switch, status, settings), with the regular integrations below on the
/// embedded web page (which leaves its own Power section out: `embed=mac-regular`).
/// Switching a protected one off asks for Face ID on the iPhone.
@Observable
@MainActor
final class MacPowerStore {
    private(set) var rows: [PowerRow] = []
    private(set) var pending: Set<String> = []
    private(set) var loaded = false
    var message: String?
    @ObservationIgnored private let api: PowerAPI

    init(api: PowerAPI = PowerAPI(client: "mac")) { self.api = api }

    func load() async {
        do {
            apply(try await api.list())
        } catch {
            message = "Couldn't reach Jarvis: \(error.localizedDescription)"
        }
    }

    func apply(_ body: [String: Any]) {
        rows = (body["integrations"] as? [[String: Any]] ?? []).compactMap(PowerRow.init(json:))
        pending.subtract(rows.filter { !$0.enabled }.map(\.id))
        loaded = true
    }

    func set(_ id: String, enabled: Bool) async { await change(id, ["enabled": enabled]) }

    func setSetting(_ id: String, _ key: String, _ value: Any) async { await change(id, ["settings": [key: value]]) }

    private func change(_ id: String, _ body: [String: Any]) async {
        do {
            let reply = try await api.change(id, body: body)
            if reply["pending"] != nil {
                pending.insert(id)
                message = "Approve it with Face ID on your iPhone."
            } else if reply["ok"] as? Bool == false {
                message = reply["error"] as? String ?? "That didn't work."
            }
        } catch {
            message = error.localizedDescription
        }
        await load()
    }

    func subtitle(_ row: PowerRow) -> String {
        if pending.contains(row.id) { return "Waiting for Face ID on your iPhone" }
        if !row.enabled { return "Off" }
        return row.statusLine.isEmpty ? row.summary : row.statusLine
    }
}

struct MacIntegrationsPane: View {
    @State private var store = MacPowerStore()
    @State private var open: String?

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("POWER").font(.system(size: 11, weight: .medium)).tracking(0.8)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                    }
                    if let message = store.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(store.rows) { row in
                        MacPowerRowView(row: row, store: store, expanded: open == row.id) {
                            open = open == row.id ? nil : row.id
                        }
                    }
                    if !store.loaded { JcLoader().frame(maxWidth: .infinity).padding(20) }
                }
                .padding(16)
            }
            .frame(minHeight: 200, idealHeight: 360)
            MacServerSettingsPane(section: "", panel: "tasks", embed: "mac-regular")
                .frame(minHeight: 200)
        }
        .task { await store.load() }
    }
}

private struct MacPowerRowView: View {
    let row: PowerRow
    @Bindable var store: MacPowerStore
    let expanded: Bool
    let toggleOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: row.icon)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 13, weight: .semibold))
                        Text("Power").font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().stroke(.secondary.opacity(0.4)))
                            .foregroundStyle(.secondary)
                    }
                    Text(store.subtitle(row)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: toggleOpen) { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                Toggle("", isOn: Binding(get: { row.enabled },
                                         set: { on in Task { await store.set(row.id, enabled: on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(store.pending.contains(row.id))
            }
            if let error = row.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if expanded {
                Text(row.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(row.settingsSchema) { setting in MacPowerSettingField(row: row, setting: setting, store: store) }
            }
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .opacity(row.enabled ? 1 : 0.75)
    }
}

private struct MacPowerSettingField: View {
    let row: PowerRow
    let setting: PowerSetting
    @Bindable var store: MacPowerStore
    @State private var draft = ""

    var body: some View {
        let value = row.settings[setting.key] ?? .none
        HStack {
            Text(setting.label).font(.system(size: 12))
            Spacer()
            switch setting.kind {
            case .toggle:
                Toggle("", isOn: Binding<Bool>(
                    get: { if case .bool(let b) = value { return b } else { return false } },
                    set: { on in Task { await store.setSetting(row.id, setting.key, on) } }))
                    .toggleStyle(.switch).labelsHidden()
            case .picker:
                Picker("", selection: Binding<String>(
                    get: { if case .text(let t) = value { return t } else { return "" } },
                    set: { v in Task { await store.setSetting(row.id, setting.key, v) } })) {
                    ForEach(setting.options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().frame(maxWidth: 180)
            case .secret:
                Text(Self.isSet(value) ? "Set" : "Not set").font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("Replace", text: $draft).frame(maxWidth: 180)
                    .onSubmit { submit(draft) }
            case .number, .text:
                TextField(Self.text(value), text: $draft).frame(maxWidth: 180)
                    .onSubmit {
                        if setting.kind == .number, let n = Double(draft) {
                            submit(n == n.rounded() ? Int(n) as Any : n as Any)
                        } else if setting.kind == .text { submit(draft) }
                    }
                if !setting.unit.isEmpty { Text(setting.unit).foregroundStyle(.secondary) }
            }
        }
    }

    private func submit(_ value: Any) {
        if let s = value as? String, s.isEmpty { return }
        Task { await store.setSetting(row.id, setting.key, value) }
        draft = ""
    }

    static func isSet(_ value: PowerValue) -> Bool {
        if case .secretSet(true) = value { return true }
        return false
    }

    static func text(_ value: PowerValue) -> String {
        switch value {
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .text(let t): return t
        default: return ""
        }
    }
}
