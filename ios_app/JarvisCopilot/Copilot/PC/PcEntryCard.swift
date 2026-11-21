import SwiftUI

/// Words on the PC's card and info sheets (pure, tested).
enum PcCardCopy {
    /// The lights pill: what the PC shows, or nil when PC Lighting is off or nothing is known.
    static func lights(state: PcLightingState?, map: PcLedMap?, powerOn: Bool) -> String? {
        guard powerOn, let state else { return nil }
        guard map?.isMapped == true else { return "Set up" }
        guard state.on else { return "Off" }
        let effects = Set(PcPart.allCases.map { state.light($0).effect })
        guard effects.count == 1, let only = effects.first else { return "Mixed" }
        return PcEffect(rawValue: only)?.label ?? only.capitalized
    }
}

/// What a tapped part of the model is, from the PC's specs and its live numbers.
struct PcComponentInfo: Identifiable, Equatable {
    struct Row: Equatable { let label: String; let value: String }
    let id: String
    let title: String
    let subtitle: String?
    let rows: [Row]

    static func make(_ id: String, specs: PcSpecs?, summary: PcSummary?) -> PcComponentInfo {
        func pct(_ v: Double?) -> String? { v.map { "\(Int($0.rounded()))%" } }
        func deg(_ v: Double?) -> String? { v.map { "\(Int($0.rounded()))°C" } }
        func rows(_ pairs: [(String, String?)]) -> [Row] { pairs.compactMap { p in p.1.map { Row(label: p.0, value: $0) } } }
        switch id {
        case "gpu":
            let g = specs?.gpus?.first
            return .init(id: id, title: g?.name ?? "Graphics card", subtitle: "MSI Shadow 3X",
                         rows: rows([("Load", pct(summary?.gpu)), ("Temperature", deg(summary?.gpuTemp)),
                                     ("Memory", g?.vramMb.map { "\(Int((Double($0) / 1024).rounded())) GB" }),
                                     ("Driver", g?.driver)]))
        case "ram":
            let m = specs?.memory
            let total = m?.totalMb.map { "\($0 / 1024) GB memory" } ?? "Memory"
            let mods = (m?.modules ?? []).enumerated().map { i, mod in
                Row(label: "Stick \(i + 1)", value: [mod.maker, mod.part, mod.sizeMb.map { "\($0 / 1024) GB" },
                                                      mod.mhz.map { "\($0) MT/s" }].compactMap { $0 }.joined(separator: " · "))
            }
            return .init(id: id, title: total, subtitle: "T-Force DDR5", rows: mods)
        case "board":
            let b = specs?.board
            let name = [b?.maker, b?.product].compactMap { $0 }.joined(separator: " ")
            return .init(id: id, title: name.isEmpty ? "Motherboard" : name, subtitle: nil,
                         rows: rows([("BIOS", b?.bios), ("Processor", specs?.cpu?.name),
                                     ("CPU load", pct(summary?.cpu)), ("CPU temperature", deg(summary?.cpuTemp))]))
        case "radiator":
            return .init(id: id, title: "Liquid cooler", subtitle: "240 mm radiator",
                         rows: rows([("CPU temperature", deg(summary?.cpuTemp)), ("CPU load", pct(summary?.cpu))]))
        case "psu":
            return .init(id: id, title: "Power supply", subtitle: "CyberPower",
                         rows: rows([("Whole PC (est.)", summary?.watts.map { "\(Int($0.rounded())) W" })]))
        default:
            let s = specs?.system
            let name = [s?.maker, s?.model].compactMap { $0 }.joined(separator: " ")
            return .init(id: id, title: name.isEmpty ? "Your PC" : name, subtitle: "Glass dual-chamber case",
                         rows: rows([("Processor", specs?.cpu?.name), ("Graphics", specs?.gpus?.first?.name)]))
        }
    }
}

/// The PC's card on Devices → Wearables: the model in its current colours (a still), status and lights.
struct PcEntryCard: View {
    var namespace: Namespace.ID
    @State private var summary: PcSummary?

    private var agents: AgentsStore { .shared }
    private var store: PcStore { .shared }

    var body: some View {
        Group {
            if let mac = agents.macs.first(where: { $0.isPC }) {
                NavigationLink {
                    PcPage(deviceId: mac.deviceId).zoomTransition(id: "pc", in: namespace)
                } label: {
                    card(mac)
                }
                .buttonStyle(.plain)
                .zoomSource(id: "pc", in: namespace)
            }
        }
        .task {
            if !agents.loaded { await agents.refresh() }
            if !store.loaded { await store.refresh() }
            if PowerState.shared.isOn("pc-stats"), let id = agents.macs.first(where: { $0.isPC })?.deviceId {
                summary = try? await PcStatsClient().summary(deviceId: id)
            }
        }
    }

    private func card(_ mac: AgentMacPower) -> some View {
        let lightsOn = PowerState.shared.isOn("pc-lighting")
        let status = AgentsMacPowerCopy.status(mac, now: .now)
        return DeviceCard(name: AgentsMacPowerCopy.cardName(mac.name, os: mac.os), subtitle: status.label, pictureAtTop: true) {
            PcModelView(state: store.state, map: store.map, lit: lightsOn && mac.isAwake && store.isMapped)
                .environment(\.sceneStills, true)
                .frame(width: 210, height: 160)
                .padding(.trailing, -10)
                .allowsHitTesting(false)
        } pills: {
            MetricPill(icon: "power", label: "Status", value: mac.isAwake ? "Awake" : "Asleep",
                       tint: mac.isAwake ? JcTheme.success : JcTheme.muted)
            if mac.isAwake, let gpu = summary?.gpu {
                MetricPill(icon: "cpu", label: "GPU", value: "\(Int(gpu.rounded()))%", tint: JcTheme.text)
            }
            if let lights = PcCardCopy.lights(state: store.state, map: store.map, powerOn: lightsOn) {
                MetricPill(icon: "rainbow", label: "Lights", value: lights, tint: JcTheme.text)
            }
        }
    }
}
