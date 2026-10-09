import SwiftUI

/// The car's page, after Tesla's app: status, the car, range and quick actions, rows that open
/// Controls / Climate / Status / Location / Health (the car gliding overhead in each), then the
/// lighting controls, what is linked to the car, and the Toyota account.
struct CarPage: View {
    @ObservedObject private var presence: CarPresence = .shared
    @ObservedObject private var links: WearableLinks = .shared
    @ObservedObject private var bridge: BridgeClient = .shared
    @ObservedObject private var toyota: ToyotaStore = .shared
    @State private var sheet: CarSheet?
    @State private var renaming = false
    @State private var shared = BridgeClient.isExposed(CarDevice.shared.deviceID)
    /// The one live car the page and the screens it opens share.
    @StateObject private var stage = CarStage()
    @Namespace private var cards

    private var car: CarDevice { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CarToyotaHome(store: toyota, stage: stage, presence: presence, profile: car.profile)
                // Today only the car lights add controls here.
                WearableControlsSection(title: "Lighting controls", controls: car.controls) { id, value in
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
        .onAppear { toyota.loadIfNeeded() }
        .task { await stage.load() }
        // Outside .refreshable: a pull inside a sheet must not wake the car.
        .sheet(item: $sheet) { _ in ToyotaSignInSheet(store: toyota) }
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
}
