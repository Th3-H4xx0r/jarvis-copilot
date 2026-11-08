import SwiftUI

/// The lights' card on the car's page (they're linked to the car): the cabin from above with the
/// lamps glowing, or "Pair your car lights" until a controller is paired.
struct CarLightsEntryCard: View {
    var namespace: Namespace.ID
    @ObservedObject private var manager: CarLightsManager = .shared
    @ObservedObject private var store: CarLightLayoutStore = .shared

    var body: some View {
        NavigationLink {
            CarLightsPage().zoomTransition(id: CarLightsDevice.kind, in: namespace)
        } label: {
            CarLightsCard(layout: store.layout, look: CarLightsScene.look(manager: manager),
                          status: CarLightsDevice.shared.linkStatus,
                          paired: !manager.controllers.isEmpty)
        }
        .buttonStyle(.plain)
        .zoomSource(id: CarLightsDevice.kind, in: namespace)
    }
}

struct CarLightsCard: View {
    let layout: CarLightLayout
    let look: CarLightsScene.Look
    let status: LinkedWearableStatus
    let paired: Bool

    var body: some View {
        DeviceCard(name: "Car lights", subtitle: paired ? "Magic Lantern · \(layout.lamps.count) lamps" : "Pair your car lights") {
            CarLightsPreview(layout: layout, look: look)
                .frame(width: 150, height: 190)
                .padding(.trailing, 6)
                .allowsHitTesting(false)
        } pills: {
            MetricPill(icon: paired ? "light.strip.2" : "plus.circle", label: "Status",
                       value: paired ? status.text : "Not paired",
                       tint: status.connected ? JcTheme.success : .secondary)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }
}
