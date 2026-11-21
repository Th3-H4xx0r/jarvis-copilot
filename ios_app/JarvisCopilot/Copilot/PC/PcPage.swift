import SwiftUI

/// The PC's page (from its Wearables card): the glowing model, the same controls as the Agents tab's
/// PC card (that card itself, not a copy), lighting and specs.
struct PcPage: View {
    let deviceId: String

    @State private var component: PcComponentInfo?
    @State private var selectedPart: PcPart?

    private var agents: AgentsStore { .shared }
    private var store: PcStore { .shared }
    private var mac: AgentMacPower? { agents.macs.first { $0.deviceId == deviceId } ?? agents.macs.first { $0.isPC } }

    /// The model glows only while the lights are really Jarvis's to show.
    private var lightsLive: Bool {
        PowerState.shared.isOn("pc-lighting") && store.online && store.isMapped && store.engine != "stopped"
            && (mac?.isAwake ?? false)
    }

    var body: some View {
        ScrollView {
            JcPageColumn {
                PcModelView(state: store.state, map: store.map, lit: lightsLive,
                            onTapPart: { selectedPart = $0 },
                            onTapComponent: { id in Task { await showComponent(id) } })
                    .frame(height: 330)
                    .padding(.horizontal, -8)
                if let mac {
                    JcSectionLabel("Controls")
                    AgentsMacPowerCard(mac: mac, store: agents)
                }
                PcPageExtras(selectedPart: $selectedPart)
            }
        }
        .refreshable { await store.refresh(); await agents.refresh() }
        .jcPageChrome(mac.map { AgentsMacPowerCopy.cardName($0.name, os: $0.os) } ?? "PC")
        .navigationDestination(for: AgentsRoute.self) { route in
            switch route {
            case .pcStats(let id, let name): PcStatsPage(deviceId: id, name: name)
            case .computerTools(let id, let name): ComputerToolsPage(deviceId: id, name: name, store: agents)
            default: EmptyView()
            }
        }
        .onAppear { agents.watch("pc-page", true); store.watch(true) }
        .onDisappear { agents.watch("pc-page", false); store.watch(false) }
        .sheet(item: $component) { PcComponentSheet(info: $0) }
    }

    private func showComponent(_ id: String) async {
        if !store.specsLoaded { await store.loadSpecs() }
        let summary = PowerState.shared.isOn("pc-stats") ? try? await PcStatsClient().summary(deviceId: deviceId) : nil
        component = PcComponentInfo.make(id, specs: store.specs, summary: summary)
    }
}

/// The page's lower sections (lighting, specs); filled in by their own files.
struct PcPageExtras: View {
    @Binding var selectedPart: PcPart?

    var body: some View {
        EmptyView()
    }
}

struct PcComponentSheet: View {
    let info: PcComponentInfo

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    if let sub = info.subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(JcTheme.muted)
                    }
                    JcCard(padding: 0) {
                        ForEach(Array(info.rows.enumerated()), id: \.offset) { i, row in
                            JcRow(title: row.label, value: row.value, last: i == info.rows.count - 1)
                        }
                    }
                }
            }
            .jcPageChrome(info.title, header: .inline)
        }
        .presentationDetents([.medium])
    }
}
