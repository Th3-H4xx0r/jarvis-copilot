import SwiftUI

/// Ray-Ban Meta (Gen 2) on Devices → Wearables: the 3D glasses, mirroring the simulator while Sim
/// is selected (capture LED, folded), with status pills.
struct MetaGlassesCard: View {
    @ObservedObject private var hub = MetaGlassesHub.shared

    var body: some View {
        if hub.mode == .sim {
            MetaGlassesSimCard(sim: hub.simulator)
        } else {
            DeviceCard(name: "Meta glasses", subtitle: MetaGlassesDevice.model) {
                MetaGlassesSceneView(spin: false, ledOn: false, folded: false)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            } pills: {
                MetricPill(icon: "link", label: "Status", value: "Not paired yet", tint: JcTheme.muted)
            }
        }
    }
}

private struct MetaGlassesSimCard: View {
    @ObservedObject var sim: SimulatedGlassesTransport

    var body: some View {
        DeviceCard(name: "Meta glasses", subtitle: "\(MetaGlassesDevice.model) · Simulated") {
            MetaGlassesSceneView(spin: true, ledOn: sim.ledLit, folded: sim.hw.folded)
                .frame(width: 124, height: 124)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        } pills: {
            MetricPill(icon: "testtube.2", label: "Status", value: "Simulated", tint: JcTheme.muted)
            MetricPill(icon: sim.hw.charging ? "battery.100.bolt" : "battery.75", label: "Battery",
                       value: "\(Int(sim.hw.battery.rounded()))%",
                       tint: sim.hw.battery <= 20 ? JcTheme.danger : JcTheme.success)
        }
    }
}

/// The glasses page. A full-width Device | Sim toggle on top picks which glasses Jarvis talks to:
/// Device is the real-glasses screen (waiting for the hardware); Sim is the hardware simulator —
/// controls, glasses state, the live command feed, camera/storage — over the same tools and code.
struct MetaGlassesView: View {
    @ObservedObject private var hub = MetaGlassesHub.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                JcSegmentedPicker(MetaGlassesHub.Mode.allCases.map { (value: $0, label: $0.label) },
                                  selection: Binding(get: { hub.mode }, set: { select($0) }))
                    .padding(.bottom, 6)
                if hub.mode == .sim {
                    MetaSimScreen(sim: hub.simulator, hub: hub)
                } else {
                    MetaDeviceScreen(hub: hub)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(JcTheme.bg.ignoresSafeArea())
        .jcPageChrome("Meta glasses")
    }

    private func select(_ mode: MetaGlassesHub.Mode) {
        let hub = self.hub
        Task { @MainActor in await hub.setMode(mode) }
    }

    static func seconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f s", ms / 1000)
    }
}

// MARK: - Device (the real glasses)

private struct MetaDeviceScreen: View {
    @ObservedObject var hub: MetaGlassesHub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetaGlassesSceneView(spin: true, ledOn: false, folded: false)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            Text("Your Ray-Ban Meta glasses aren't paired yet. This screen lights up when they arrive; until then, switch to Sim to test everything against the simulator.")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            JcSectionLabel("Connection")
            JcCard(padding: 0) {
                VStack(spacing: 0) {
                    JcRow(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth link",
                          subtitle: "Built when the glasses are here", value: "Waiting")
                    JcRow(symbol: "person.badge.key", title: "Ownership",
                          subtitle: "A one-time setup you do with the glasses", value: "Waiting")
                    JcRow(symbol: "waveform.badge.mic", title: "“Hey Jarvis” on the glasses",
                          subtitle: "Enrolled on the glasses (3 samples, US English)", value: "Waiting", last: true)
                }
            }
            GradientButton("Pair glasses", symbol: "link", full: true, action: nil)
                .padding(.top, 12)

            MetaTouchSettingsCard(hub: hub)
            MetaFeedCard(feed: hub.feed, emptyText: "Commands to the real glasses show here.")
            MetaLimitsCard()
        }
    }
}
