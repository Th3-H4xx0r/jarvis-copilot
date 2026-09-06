import SwiftUI

/// The Devices tab. Two halves of the same question — "what can Jarvis reach?" —
/// behind one segmented control:
///
/// * **Server** ports `pages/devices_page.dart`: everything paired with the
///   Jarvis server (this phone included), each device's granted skills, log out
///   and revoke, the server-health / wiki strip and the pair-another-device flow.
/// * **Wearables** is this app's own BLE scanner (`ScanView`), which predates the
///   port and owns the ESP32 / bottle / scale hardware.
///
/// A segmented control rather than one scroll: `ScanView` brings its own
/// scroller, so stacking it inside another scroll view would break both.
///
/// This page owns the tab's single `NavigationStack`. `ScanView` used to bring
/// one of its own, which drew a SECOND navigation bar under the segmented picker
/// and painted its opaque system background over the aurora; embedded it now
/// lends its toolbar (gear + Rescan) to this bar instead (`ScanView(embedded:)`).
struct DevicesPage: View {
    /// Wearables first: the BLE scanner is what this app was before the port and
    /// what the user reaches for most.
    @State private var section: DevicesSection
    @State private var store: DevicesStore

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: DevicesStore? = nil, section: DevicesSection = .wearables) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { DevicesStore() })
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Narrow and centred, the way a first-party app uses a segmented
                // control. Stretched edge to edge it read as a pair of giant buttons
                // and dominated everything under it. NOT `.fixedSize()`: a segmented
                // picker reports no ideal width, so that collapses it to nothing.
                Picker("Devices", selection: $section) {
                    ForEach(DevicesSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)

                switch section {
                case .server:
                    DevicesServerSection(store: store)
                        .loadErrorBanner(store.errorMessage, hasContent: !store.devices.isEmpty)
                case .wearables:
                    // Chrome-less: this page's stack and bar host it.
                    ScanView(embedded: true)
                }
            }
            // Behind the WHOLE page, not just the server half: an `ignoresSafeArea`
            // background on the lower view expands past its own frame and paints
            // over the segmented control above it, which is how the picker went
            // missing. The wearables half gets it too now — its own opaque
            // navigation background used to sit over it as a flat black slab.
            .jcScreen("Devices")
        }
    }
}

/// Which half of the Devices tab is showing.
enum DevicesSection: String, CaseIterable, Identifiable {
    case server, wearables

    var id: String { rawValue }

    /// One word each. The old labels ("This phone & server") were a sentence in a
    /// control that is only ever read at a glance.
    var title: String {
        switch self {
        case .server:    return "Server"
        case .wearables: return "Wearables"
        }
    }
}

// MARK: - Server devices

/// The `/api/devices` half: the server summary, the paired devices, pairing.
struct DevicesServerSection: View {
    @Bindable var store: DevicesStore

    @State private var confirming: DevicesConfirmation?
    @State private var pairing = false

    var body: some View {
        content
            .task { if !store.hasLoaded { store.load() } }
            .moreToast($store.toast)
            .sheet(isPresented: $pairing) { DevicePairSheet(store: store) }
            .alert(confirming?.title ?? "", isPresented: confirmingBinding, presenting: confirming) { action in
                Button("Cancel", role: .cancel) {}
                Button(action.confirmTitle, role: action.destructive ? ButtonRole.destructive : nil) {
                    let device = action.device
                    let kind = action.kind
                    Task {
                        switch kind {
                        case .logout: await store.logout(device)
                        case .revoke: await store.revoke(device)
                        }
                    }
                }
            } message: { action in
                Text(action.message)
            }
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    /// The record for the phone this app runs on, so exactly one row can be
    /// tagged. Computed once per render rather than per row.
    private var thisDeviceID: String? { DevicesLocal.thisDeviceID(in: store.devices) }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage, store.devices.isEmpty {
            // A card, not two lines of coloured text in the void: this is the
            // whole screen when the server is unreachable, and it should look
            // like a considered state rather than a crash.
            DevicesErrorState(message: message) { store.load() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DevicesHealthStrip(health: store.health, wiki: store.wiki)
                    devices
                    // The blue CTA rather than the iridescent one: this screen's
                    // whole problem was competing colours, and the brand sweep
                    // under three grey cards reads as a candy bar. Blue is the
                    // reference's colour for the single commit action on a page.
                    BlueButton(store.isEmpty ? "Pair a device" : "Pair another device") {
                        pairing = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private var devices: some View {
        if store.isEmpty {
            // No header over an empty list: a heading with nothing under it reads
            // as a screen that failed to load rather than one with nothing to say.
            DevicesEmptyState()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Paired devices") {
                    Text("\(store.devices.count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                }
                VStack(spacing: 10) {
                    ForEach(store.devices) { device in
                        DeviceServerCard(device: device,
                                         skills: store.grantedSkills(for: device),
                                         isThisDevice: device.id == thisDeviceID,
                                         onLogout: {
                                             confirming = .init(device: device, kind: .logout)
                                         },
                                         onRevoke: {
                                             confirming = .init(device: device, kind: .revoke)
                                         })
                    }
                }
            }
        }
    }
}

/// A pending destructive action, so one alert covers both menu items.
struct DevicesConfirmation: Identifiable {
    enum Kind { case logout, revoke }

    let device: Device
    let kind: Kind

    var id: String { "\(device.id)-\(kind == .logout ? "logout" : "revoke")" }
    var destructive: Bool { kind == .revoke }

    var title: String {
        kind == .logout ? "Log out \(device.displayName)?" : "Revoke \(device.displayName)?"
    }

    /// Naming the verb beats "Confirm": in a two-button alert the label is the
    /// only place the consequence is restated.
    var confirmTitle: String { kind == .logout ? "Log out" : "Revoke" }

    var message: String {
        kind == .logout ? "It will need to sign in again before Jarvis can reach it."
                        : "It will be removed from this server and signed out."
    }
}
