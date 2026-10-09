import SwiftUI

/// The car's page: the car, Toyota's Remote · Status · Health, its Controls, what is linked to it,
/// then the Toyota account.
struct CarPage: View {
    @ObservedObject private var presence: CarPresence = .shared
    @ObservedObject private var links: WearableLinks = .shared
    @ObservedObject private var bridge: BridgeClient = .shared
    @ObservedObject private var toyota: ToyotaStore = .shared
    @State private var sheet: CarSheet?
    @State private var renaming = false
    @State private var shared = BridgeClient.isExposed(CarDevice.shared.deviceID)
    @Namespace private var cards

    private var car: CarDevice { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                CarToyotaSection(store: toyota) { sheet = $0 }
                WearableControlsSection(controls: car.controls) { id, value in
                    try await links.perform(id, value: value, on: CarDevice.kind)
                }
                LinkedWearablesSection(hostKind: CarDevice.kind, hostName: car.name, namespace: cards)
                sharing
                ToyotaAccountCard(store: toyota) { sheet = .signIn }
            }
            .padding(.vertical, 12)
        }
        // Pulling down wakes the car for fresh status, like Toyota's app.
        .refreshable { await toyota.refresh() }
        .task { await toyota.load() }
        // Outside .refreshable: a pull inside a sheet must not wake the car.
        .sheet(item: $sheet) { which in
            switch which {
            case .climate: CarClimateSheet(store: toyota)
            case .find: CarFindSheet(car: toyota.car)
            case .signIn: ToyotaSignInSheet(store: toyota)
            }
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
            if CarModel.hasBundledModel {
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
