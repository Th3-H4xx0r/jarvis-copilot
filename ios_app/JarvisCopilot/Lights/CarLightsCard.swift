import SwiftUI

/// The lights' card on the car's page (they're linked to the car): the cabin from above with the
/// lamps glowing, or "Pair your car lights" until a controller is paired.
struct CarLightsEntryCard: View {
    var namespace: Namespace.ID
    @ObservedObject private var manager: CarLightsManager = .shared

    var body: some View {
        NavigationLink {
            CarLightsPage().zoomTransition(id: CarLightsDevice.kind, in: namespace)
        } label: {
            CarLightsCard(looks: CarLightsScene.looks(layout: .bundled, manager: manager),
                          status: CarLightsDevice.shared.linkStatus,
                          paired: !manager.controllers.isEmpty,
                          lampCount: CarLightLayout.bundled.lamps.count)
        }
        .buttonStyle(.plain)
        .zoomSource(id: CarLightsDevice.kind, in: namespace)
    }
}

struct CarLightsCard: View {
    let looks: [String: CarLightsScene.Look]
    let status: LinkedWearableStatus
    let paired: Bool
    let lampCount: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                CarLightsPreview(looks: looks)
                    .frame(width: 150, height: 190)
                    .padding(.trailing, 6)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Car lights").font(.title3.weight(.semibold)).lineLimit(1)
                Text(paired ? "Magic Lantern · \(lampCount) lamps" : "Pair your car lights")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                Spacer(minLength: 0)
                MetricPill(icon: paired ? "light.strip.2" : "plus.circle", label: "Status",
                           value: paired ? status.text : "Not paired",
                           tint: status.connected ? JcTheme.success : .secondary)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}
