import SwiftUI

struct ScanView: View {
    // App-lifetime managers (see `WearablesHub`): this view only *shows* them.
    @ObservedObject private var manager = WearablesHub.shared.bottle
    @ObservedObject private var scaleManager = WearablesHub.shared.scale
    @ObservedObject private var esp32Manager = WearablesHub.shared.esp32
    @Environment(\.scenePhase) private var scenePhase

    private let spacing: CGFloat = 14
    /// device_id of the card whose "Try to connect" is in flight.
    @State private var connecting: String?
    @Namespace private var cardNamespace

    var body: some View {
        // The Devices tab's NavigationStack carries the bar (so `.toolbar` lands
        // there) and its aurora shows through.
        scroller.toolbar { scanToolbar }
    }

    private var scroller: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if manager.discovered.isEmpty && scaleManager.discovered.isEmpty
                    && esp32Manager.discovered.isEmpty && absent.isEmpty {
                    emptyState
                } else {
                    grid
                    scanningRow
                }
                scannerFooter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ToolbarContentBuilder private var scanToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            NavigationLink {
                BridgeSettingsView()
            } label: {
                Image(systemName: "gearshape")
            }
            Button("Rescan", systemImage: "arrow.clockwise") { WearablesHub.shared.rescanAll() }
                .disabled(!manager.bluetoothReady)
        }
    }

    // MARK: Device list

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(manager.discovered) { bottle in
                NavigationLink {
                    DeviceView(manager: manager, bottle: bottle)
                        .zoomTransition(id: bottle.id, in: cardNamespace)
                } label: {
                    BottleCard(bottle: bottle)
                }
                .buttonStyle(.plain)
                .zoomSource(id: bottle.id, in: cardNamespace)
            }
            ForEach(scaleManager.discovered) { scale in
                NavigationLink {
                    ScaleDeviceView(manager: scaleManager, scale: scale)
                        .zoomTransition(id: scale.id, in: cardNamespace)
                } label: {
                    ScaleCard(scale: scale)
                }
                .buttonStyle(.plain)
                .zoomSource(id: scale.id, in: cardNamespace)
            }
            ForEach(esp32Manager.discovered) { board in
                NavigationLink {
                    Esp32DeviceView(manager: esp32Manager, board: board)
                        .zoomTransition(id: board.id, in: cardNamespace)
                } label: {
                    Esp32Card(board: board,
                              activeLink: esp32Manager.connected?.id == board.id && esp32Manager.state == .ready
                                  ? esp32Manager.activeLink : nil)
                }
                .buttonStyle(.plain)
                .zoomSource(id: board.id, in: cardNamespace)
            }
            ForEach(absent) { entry in
                AbsentDeviceCard(entry: entry, busy: connecting == entry.deviceID) {
                    connecting = entry.deviceID
                    Task {
                        _ = await WearablesHub.shared.connect(deviceID: entry.deviceID)
                        connecting = nil
                    }
                }
            }
        }
    }

    /// Paired devices this scan didn't turn up.
    ///
    /// The list used to be the live scan buffer alone, so a bottle that was merely
    /// out of range vanished from the Devices tab entirely — indistinguishable from
    /// one that was never paired. They keep their card and say what's wrong instead.
    private var absent: [WearableEntry] {
        WearablesHub.shared.roster().filter { !$0.connected && !$0.seenInLastScan }
    }

    // MARK: Chrome

    @ViewBuilder private var emptyState: some View {
        if manager.bluetoothReady {
            VStack(spacing: 18) {
                ScanRadar()
                Text("Looking for devices…")
                    .foregroundStyle(.secondary)
                Text("Boards already on Wi‑Fi appear here too.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.orange)
                Text("Turn on Bluetooth")
                    .font(.headline)
                Text("Jarvis devices are found and set up over Bluetooth. Boards already on Wi‑Fi still show up here.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                if let url = URL(string: "App-Prefs:root=Bluetooth") {
                    Link("Open Settings", destination: url).font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        }
    }

    /// Sits under the cards while the Bluetooth scan is still running, so a list that
    /// only has Wi‑Fi boards in it doesn't look finished.
    @ViewBuilder private var scanningRow: some View {
        if manager.bluetoothReady {
            HStack(spacing: 10) {
                ScanRadar(size: 36)
                Text("Searching for Bluetooth devices…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
                Text("Turn on Bluetooth to find more devices")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    private var scannerFooter: some View {
        Toggle("Only Jarvis devices", isOn: Binding(
            get: { manager.strictNameMatch && scaleManager.strictNameMatch && esp32Manager.strictNameMatch },
            set: { enabled in
                manager.strictNameMatch = enabled
                scaleManager.strictNameMatch = enabled
                esp32Manager.strictNameMatch = enabled
            }
        ))
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Expanding rings, like a radar sweep — visibly different from the plain spinner so
/// "scanning" and "Bluetooth is off" never look alike.
private struct ScanRadar: View {
    /// Overall footprint; the rings grow to fill it.
    var size: CGFloat = 140
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size * 0.29, height: size * 0.29)
                    .scaleEffect(animate ? 3.2 : 1)
                    .opacity(animate ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                               value: animate)
            }
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.2, weight: .light))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
        .onAppear { animate = true }
    }
}

private struct ScaleCard: View {
    let scale: DiscoveredScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScaleSceneView(state: .idle, weightText: nil, entrance: false,
                           presentation: .card)
                .frame(width: 275, height: 190)
                .offset(x: 116, y: -4)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                Text(scale.name.isEmpty ? "ESF551" : scale.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 190, alignment: .leading)
                Text("Etekcity body scale")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                Spacer()
                MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                           value: scale.rssi == 0 ? "Known" : "\(scale.rssi) dBm",
                           tint: signalTint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    private var signalTint: Color {
        switch scale.rssi {
        case 0: return .blue
        case (-68)...: return Color(red: 0.29, green: 0.82, blue: 0.49)
        case (-82)..<(-68): return .orange
        default: return Color(red: 1.0, green: 0.31, blue: 0.27)
        }
    }
}

// MARK: - Card

private struct BottleCard: View {
    static let cardHeight: CGFloat = 190
    /// How far the model runs past the card's bottom edge.
    static let bleed: CGFloat = 46

    let bottle: DiscoveredBottle

    var body: some View {
        ZStack(alignment: .topLeading) {
            if bottle.hasModel {
                // Whole bottle, leaning, sitting in the right of the card and running a
                // little past its bottom edge — the camera does the placing, so nothing
                // is cropped mid-body.
                BottleSceneView(spin: true, tilt: -0.16,
                                cameraX: -0.31, cameraY: 0.16, cameraZ: 2.6)
                    .frame(height: Self.cardHeight + Self.bleed)
                    .padding(.bottom, -Self.bleed)
            } else {
                HStack {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 34)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(bottle.name.isEmpty ? "Unnamed" : bottle.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 190, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    MetricPill(icon: "antenna.radiowaves.left.and.right",
                               label: "Signal",
                               value: "\(bottle.rssi) dBm",
                               tint: signalTint)
                    SignalBars(rssi: bottle.rssi)
                }
            }
            .padding(16)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.07)))
    }

    private var signalTint: Color {
        switch bottle.rssi {
        case (-68)...:      return Color(red: 0.29, green: 0.82, blue: 0.49)
        case (-82)..<(-68): return .orange
        default:            return Color(red: 1.0, green: 0.31, blue: 0.27)
        }
    }
}

private struct SignalBars: View {
    let rssi: Int

    /// −50 dBm and better is full strength; −95 and worse is one bar.
    private var level: Int {
        switch rssi {
        case (-55)...:    return 4
        case (-68)..<(-55): return 3
        case (-80)..<(-68): return 2
        default:          return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i <= level ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(i) * 2.5 + 3)
            }
        }
    }
}

// MARK: - Zoom navigation transition

// The card grows into the detail screen on iOS 18+; older systems just get the standard
// push, so these are applied through `if #available` wrappers rather than at the call site.
extension View {
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// A paired device that isn't answering right now.
///
/// Deliberately not a `NavigationLink`: the detail screens take a `Discovered*`
/// value built from a live CoreBluetooth peripheral, and we don't have one. The
/// card offers the connect directly, and the real card takes its place once the
/// link comes up.
private struct AbsentDeviceCard: View {
    let entry: WearableEntry
    let busy: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if busy {
                ProgressView()
            } else {
                Button("Connect", action: connect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.07)))
    }

    private var subtitle: String {
        guard let seen = entry.lastSeen else { return "Not found" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let signal = entry.lastRSSI.map { " · \($0) dBm" } ?? ""
        return "Not found · last seen \(f.localizedString(for: seen, relativeTo: Date()))\(signal)"
    }
}
