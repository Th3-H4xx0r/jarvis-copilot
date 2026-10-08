import SwiftUI

/// The car's page: the car, whether the phone is with it, its Controls, then what is linked to it.
struct CarPage: View {
    @ObservedObject private var presence: CarPresence = .shared
    @ObservedObject private var links: WearableLinks = .shared
    @ObservedObject private var bridge: BridgeClient = .shared
    @State private var renaming = false
    @State private var shared = BridgeClient.isExposed(CarDevice.shared.deviceID)
    @Namespace private var cards

    private var car: CarDevice { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                WearableControlsSection(controls: car.controls) { id, value in
                    try await links.perform(id, value: value, on: CarDevice.kind)
                }
                LinkedWearablesSection(hostKind: CarDevice.kind, hostName: car.name, namespace: cards)
                sharing
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(car.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WearableMoreMenu(onRename: { renaming = true })
            }
        }
        .wearableRename(isPresented: $renaming, current: car.name) { name in
            WearableNames.shared.rename(CarDevice.kind, to: name)
        }
    }

    private var sharing: some View {
        CardGroup("Jarvis Copilot",
                  footer: bridge.isPaired
                      ? "Lets Jarvis see whether you're in the car, what's linked to it, and use its controls."
                      : "Pair with a Jarvis Copilot server from the device-list settings first.") {
            Row {
                Toggle("Share with Jarvis", isOn: Binding(
                    get: { shared },
                    set: { on in
                        shared = on
                        BridgeClient.setExposed(on, for: car.deviceID)
                        car.refreshMembership()
                    }))
            }
            .disabled(!bridge.isPaired)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            if CarModel.bundled != nil {
                // Swipe sideways to turn it; it carries on turning by itself once let go.
                CarSceneView(presentation: .hero, lit: presence.inCar, spinSeconds: 50, turnable: true)
                    .frame(height: 220)
            }
            VStack(spacing: 3) {
                Text(car.profile.description).font(.headline)
                Text("\(car.profile.colorName) · \(car.profile.colorCode)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if presence.inCar {
                    MetricPill(icon: "car", label: "Status", value: "In the car", tint: JcTheme.success)
                } else {
                    MetricPill(icon: "car", label: "Status", value: "Away", tint: .secondary)
                    if let note = DisconnectedPill.lastSeenNote(presence.lastSeen) {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
