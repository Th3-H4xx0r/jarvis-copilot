import SwiftUI

/// The parts the 3D model was built for (read off his PC on 2026-11-20). When the specs the PC reports
/// stop matching — a GPU swap, more RAM — the PC page says the model may be out of date.
enum PcBuiltFor {
    static let board = "B760M-C"
    static let gpu = "RTX 5070"
    static let ramSticks = 2

    /// nil: no specs yet (says nothing); true: the model no longer matches.
    static func outOfDate(_ specs: PcSpecs?) -> Bool? {
        guard let specs else { return nil }
        let boardOK = specs.board?.product?.localizedCaseInsensitiveContains(board) ?? true
        let gpuOK = (specs.gpus ?? []).isEmpty || (specs.gpus ?? []).contains { $0.name?.localizedCaseInsensitiveContains(gpu) ?? false }
        let ramOK = specs.memory?.modules.map { $0.count == ramSticks } ?? true
        return !(boardOK && gpuOK && ramOK)
    }
}

/// What the Jarvis app on the PC read about its hardware, and the parts it can't see.
struct PcSpecsPage: View {
    @State private var error: String?
    @State private var refreshing = false
    private var store: PcStore { .shared }

    var body: some View {
        ScrollView {
            JcPageColumn {
                if let specs = store.specs {
                    if let at = specs.readAt {
                        Text("Read \(Date(timeIntervalSince1970: at), style: .relative) ago by the Jarvis app on your PC")
                            .font(.footnote).foregroundStyle(JcTheme.muted)
                    }
                    section("Processor", [specs.cpu?.name, specs.cpu.map { c in
                        [c.cores.map { "\($0) cores" }, c.threads.map { "\($0) threads" }].compactMap { $0 }.joined(separator: " · ") }])
                    section("Graphics", (specs.gpus ?? []).flatMap { g in
                        [g.name, [g.vramMb.map { "\(Int((Double($0) / 1024).rounded())) GB" }, g.driver.map { "driver \($0)" }]
                            .compactMap { $0 }.joined(separator: " · ")] })
                    section("Motherboard", [[specs.board?.maker, specs.board?.product].compactMap { $0 }.joined(separator: " "),
                                            specs.board?.bios.map { "BIOS \($0)" }])
                    section("Memory", [specs.memory?.totalMb.map { "\($0 / 1024) GB" }] + (specs.memory?.modules ?? []).map { m in
                        [m.maker, m.part, m.sizeMb.map { "\($0 / 1024) GB" }, m.mhz.map { "\($0) MT/s" }].compactMap { $0 }.joined(separator: " · ") })
                    section("Storage", (specs.storage ?? []).map { d in
                        [d.model, d.sizeGb.map { $0 >= 1000 ? String(format: "%.1f TB", Double($0) / 1000) : "\($0) GB" }, d.kind]
                            .compactMap { $0 }.joined(separator: " · ") })
                    section("Displays", (specs.displays ?? []).map { d in
                        [d.name, d.width.flatMap { w in d.height.map { "\(w)×\($0)" } }, d.hz.map { "\($0) Hz" }]
                            .compactMap { $0 }.joined(separator: " · ") })
                    section("System", [specs.os?.name, specs.os.map { "Version \($0.version ?? "") · build \($0.build ?? "")" },
                                       [specs.system?.maker, specs.system?.model].compactMap { $0 }.joined(separator: " ")])
                } else if store.specsLoaded {
                    JcCard { Text("No specs yet. Update Jarvis on the PC, then pull to refresh.").font(.subheadline).foregroundStyle(JcTheme.muted) }
                }
                JcSectionLabel("From your photos")
                JcCard(padding: 0) {
                    JcRow(title: "Case", value: "Glass dual-chamber")
                    JcRow(title: "Cooler", value: "240 mm liquid, hex logo")
                    JcRow(title: "Fans", value: "7 × 120 mm RGB")
                    JcRow(title: "Power supply", value: "CyberPower", last: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(JcTheme.danger)
                }
            }
        }
        .refreshable { error = await store.refreshSpecs() }
        .task { if !store.specsLoaded { await store.loadSpecs() } }
        .jcPageChrome("Specs")
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String?]) -> some View {
        let shown = lines.compactMap { $0 }.filter { !$0.isEmpty }
        if !shown.isEmpty {
            JcSectionLabel(title)
            JcCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown[0]).font(.headline)
                    ForEach(shown.dropFirst(), id: \.self) { Text($0).font(.subheadline).foregroundStyle(JcTheme.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
