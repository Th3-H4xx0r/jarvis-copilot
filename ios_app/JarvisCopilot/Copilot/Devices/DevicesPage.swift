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
/// This page owns the tab's single `NavigationStack` and its chrome: the large
/// "Devices" title that folds on scroll and ONE action pill — scan a setup code,
/// and on Wearables the bridge settings and Rescan. The segmented control rides at
/// the top of whichever half's scroll view is showing, so the title folds with it.
struct DevicesPage: View {
    /// Wearables first: the BLE scanner is what this app was before the port and
    /// what the user reaches for most.
    @State private var section: DevicesSection
    @State private var store: DevicesStore
    /// Scan a Jarvis device's setup QR, then pair it in the stepper.
    @State private var scanningForDevice = false
    @State private var setupCode: PodSetupCode?
    @State private var scannedCode: PodSetupCode?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Optional so tests and previews without the shell still build the page.
    @Environment(AppRouter.self) private var router: AppRouter?
    /// Rescan waits for Bluetooth.
    @ObservedObject private var bottles = WearablesHub.shared.bottle

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: DevicesStore? = nil, section: DevicesSection = .wearables) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { DevicesStore() })
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .server:
                    DevicesServerSection(store: store, header: AnyView(sectionPicker))
                        .loadErrorBanner(store.errorMessage, hasContent: !store.devices.isEmpty)
                case .wearables:
                    ScanView(header: AnyView(sectionPicker))
                }
            }
            .jcPageChrome("Devices") {
                JcPageButton("qrcode.viewfinder", label: "Scan to add a device") { scanningForDevice = true }
                if section == .wearables {
                    NavigationLink {
                        BridgeSettingsView()
                    } label: {
                        JcIcon("gearshape", size: 17, weight: .semibold).foregroundStyle(JcTheme.text)
                    }
                    .accessibilityLabel("Bridge settings")
                    JcPageButton("arrow.clockwise", label: "Rescan") { WearablesHub.shared.rescanAll() }
                        .disabled(!bottles.bluetoothReady)
                }
            }
        }
        // The stepper opens once the camera cover has finished closing; presenting it
        // mid-dismissal gets dropped.
        .fullScreenCover(isPresented: $scanningForDevice, onDismiss: {
            if let code = scannedCode {
                scannedCode = nil
                setupCode = code
            }
        }) {
            PodScanView(onFound: { code in
                scannedCode = code
                scanningForDevice = false
            }, onClose: { scanningForDevice = false })
        }
        .fullScreenCover(item: sizeClass == .compact ? $setupCode : .constant(nil)) { code in
            PodSetupView(code: code, onClose: { setupCode = nil }) {
                Task { await JarvisPodStore.shared.refresh(force: true); await store.refresh() }
            }
        }
        .sheet(item: sizeClass == .compact ? .constant(nil) : $setupCode) { code in
            PodSetupView(code: code, onClose: { setupCode = nil }) {
                Task { await JarvisPodStore.shared.refresh(force: true); await store.refresh() }
            }
                .presentationDetents([.large])
        }
        // A card elsewhere (the Chat dashboard) asked for a particular half.
        .onChange(of: router?.screenRequestGeneration, initial: true) { _, _ in
            if let requested = router?.consumeDevicesSection() { section = requested }
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
    /// The page's Server | Wearables control, at the top of this half.
    var header: AnyView? = nil

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
            VStack(spacing: 0) {
                header
                JcLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let message = store.errorMessage, store.devices.isEmpty {
            // A card, not two lines of coloured text in the void: this is the
            // whole screen when the server is unreachable, and it should look
            // like a considered state rather than a crash.
            VStack(spacing: 0) {
                header
                DevicesErrorState(message: message) { store.load() }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    DevicesHealthStrip(health: store.health, wiki: store.wiki)
                    devices
                    // The solid CTA rather than the gradient one: this screen's
                    // whole problem was competing colours, and the brand sweep
                    // under three grey cards reads as a candy bar. The solid pill
                    // is the reference's style for the single commit action.
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
                JcSectionLabel("Paired devices", first: true) {
                    Text("\(store.devices.count)")
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

extension DevicesPage {
    /// Server | Wearables: the app's one in-page filter, narrow and centred.
    fileprivate var sectionPicker: some View {
        JcSegmented(items: DevicesSection.allCases, selection: $section, label: \.title)
            .frame(width: 260)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
    }
}
