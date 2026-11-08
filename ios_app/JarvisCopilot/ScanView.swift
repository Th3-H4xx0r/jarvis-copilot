import SwiftUI

struct ScanView: View {
    // App-lifetime managers (see `WearablesHub`): this view only *shows* them.
    @ObservedObject private var manager = WearablesHub.shared.bottle
    @ObservedObject private var scaleManager = WearablesHub.shared.scale
    @ObservedObject private var esp32Manager = WearablesHub.shared.esp32
    @ObservedObject private var ringManager = WearablesHub.shared.ring
    @ObservedObject private var x5Manager = WearablesHub.shared.x5
    @ObservedObject private var bandManager = WearablesHub.shared.band
    /// Linked wearables live on their host's page; unlinked ones keep their card here.
    @ObservedObject private var links = WearableLinks.shared

    private let spacing: CGFloat = 14
    /// device_id of the card whose "Try to connect" is in flight.
    @State private var connecting: String?
    @Namespace private var cardNamespace
    /// The Devices page's Server | Wearables control, at the top of the scroll.
    private let header: AnyView?

    init(header: AnyView? = nil) {
        self.header = header
    }

    /// The Devices tab's NavigationStack carries the bar and its actions (settings,
    /// Rescan) in the page's one action pill.
    var body: some View {
        scroller
    }

    private var scroller: some View {
        // Read once per pass: the roster is what the cards and the absent rows both work from,
        // and it records last-seen signal as a side effect.
        let entries = WearablesHub.shared.roster()
        let absent = absentDevices(from: entries)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if manager.discovered.isEmpty && scaleManager.discovered.isEmpty
                    && esp32Manager.discovered.isEmpty && ringManager.discovered.isEmpty && x5Manager.discovered.isEmpty && bandManager.discovered.isEmpty && absent.isEmpty
                    && JarvisPodStore.shared.pods.isEmpty {
                    glassesCard(entries)
                    carCards
                    emptyState
                } else {
                    grid(entries, absent: absent)
                    scanningRow
                }
                scannerFooter
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onTabVisibilityChange(.devices) { JarvisPodStore.shared.setVisible($0) }
    }

    // MARK: Device list

    private func grid(_ entries: [WearableEntry], absent: [WearableEntry]) -> some View {
        VStack(spacing: spacing) {
            ForEach(JarvisPodStore.shared.pods) { pod in
                NavigationLink {
                    JarvisPodView(podID: pod.id)
                } label: {
                    JarvisPodCard(pod: pod, status: JarvisPodStore.shared.statuses[pod.id])
                }
                .buttonStyle(.plain)
            }
            ForEach(manager.discovered) { bottle in
                deviceCard(id: bottle.id) {
                    DeviceView(manager: manager, bottle: bottle)
                } card: {
                    BottleCard(bottle: bottle,
                               connected: manager.connected?.id == bottle.id && manager.state == .ready,
                               lastSeen: lastSeen(WearableKeepAlive.bottle, in: entries))
                }
            }
            ForEach(scaleManager.discovered) { scale in
                deviceCard(id: scale.id) {
                    ScaleDeviceView(manager: scaleManager, scale: scale)
                } card: {
                    ScaleCard(scale: scale,
                              connected: scaleManager.connected?.id == scale.id && scaleManager.state == .ready,
                              lastSeen: lastSeen(WearableKeepAlive.scale, in: entries))
                }
            }
            ForEach(esp32Manager.discovered) { board in
                deviceCard(id: board.id) {
                    Esp32DeviceView(manager: esp32Manager, board: board)
                } card: {
                    Esp32Card(board: board,
                              activeLink: esp32Manager.connected?.id == board.id && esp32Manager.state == .ready
                                  ? esp32Manager.activeLink : nil,
                              // Per board: the remembered entry is one board's, not every board's.
                              lastSeen: entries.first { $0.kind == WearableKeepAlive.esp32 && $0.deviceID == board.stableID }?.lastSeen)
                }
            }
            ForEach(ringManager.discovered) { ring in
                deviceCard(id: ring.id) {
                    RingDeviceView(manager: ringManager, ring: ring)
                } card: {
                    RingCard(ring: ring,
                             battery: ringManager.connected?.id == ring.id ? ringManager.session.battery : nil,
                             connected: ringManager.connected?.id == ring.id && ringManager.state == .ready,
                             lastSeen: lastSeen(WearableKeepAlive.ring, in: entries))
                }
            }
            ForEach(x5Manager.discovered) { ring in
                deviceCard(id: ring.id) {
                    X5DeviceView(manager: x5Manager, ring: ring)
                } card: {
                    X5Card(ring: ring,
                           battery: x5Manager.connected?.id == ring.id ? x5Manager.session.battery : nil,
                           connected: x5Manager.connected?.id == ring.id && x5Manager.state == .ready,
                           lastSeen: lastSeen(WearableKeepAlive.x5ring, in: entries))
                }
            }
            ForEach(bandManager.discovered) { band in
                deviceCard(id: band.id) {
                    BandDeviceView(manager: bandManager, band: band)
                } card: {
                    BandCard(band: band,
                             battery: bandManager.connected?.id == band.id ? bandManager.session.battery : nil,
                             connected: bandManager.connected?.id == band.id && bandManager.state == .ready,
                             lastSeen: lastSeen(WearableKeepAlive.band, in: entries))
                }
            }
            glassesCard(entries)
            carCards
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

    /// A device's card, opening its page with the zoom from the card.
    private func deviceCard<ID: Hashable, Destination: View, Card: View>(
        id: ID, @ViewBuilder destination: () -> Destination, @ViewBuilder card: () -> Card
    ) -> some View {
        NavigationLink {
            destination().zoomTransition(id: id, in: cardNamespace)
        } label: {
            card()
        }
        .buttonStyle(.plain)
        .zoomSource(id: id, in: cardNamespace)
    }

    /// Paired devices with no card of their own that this scan didn't turn up.
    ///
    /// The list used to be the live scan buffer alone, so a bottle that was merely
    /// out of range vanished from the Devices tab entirely — indistinguishable from
    /// one that was never paired. They keep their card and say what's wrong instead.
    ///
    /// `listed` is what keeps a device to ONE card: a remembered board or ring is surfaced
    /// into its manager's `discovered` list with no signal reading, which drew the full card
    /// AND an "Not found" row beneath it for the same device. The card carries the offline
    /// status now, and only a device with no card at all gets a row here.
    private func absentDevices(from entries: [WearableEntry]) -> [WearableEntry] {
        entries.filter { !$0.connected && !$0.seenInLastScan && !$0.listed }
    }

    /// The INMO GO3 has no scan of ours to turn it up — iOS holds it as a headset — so its
    /// card is always here, lit while the glasses are on the audio route.
    private func glassesCard(_ entries: [WearableEntry]) -> some View {
        NavigationLink {
            InmoGo3View()
                .zoomTransition(id: WearableKeepAlive.glasses, in: cardNamespace)
        } label: {
            GlassesCard(route: GlassesAudioLink.shared.state,
                        lastSeen: lastSeen(WearableKeepAlive.glasses, in: entries))
        }
        .buttonStyle(.plain)
        .zoomSource(id: WearableKeepAlive.glasses, in: cardNamespace)
    }

    /// The car, then any linkable wearable that isn't linked to anything (the dashcam, once
    /// unlinked from the car).
    @ViewBuilder private var carCards: some View {
        CarEntryCard(namespace: cardNamespace)
        DoorAlarmEntryCard(namespace: cardNamespace)
        ForEach(links.topLevel, id: \.kind) { $0.card(namespace: cardNamespace) }
    }

    /// When this kind of device was last in range, for a card whose link is down.
    private func lastSeen(_ kind: String, in entries: [WearableEntry]) -> Date? {
        entries.first { $0.kind == kind }?.lastSeen
    }

    // MARK: Chrome

    @ViewBuilder private var emptyState: some View {
        if manager.bluetoothReady {
            VStack(spacing: 18) {
                ScanRadar()
                Text("Looking for devices…")
                    .foregroundStyle(JcTheme.muted)
                Text("Boards already on Wi‑Fi appear here too")
                    .font(JcText.small).foregroundStyle(JcTheme.muted.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        } else {
            VStack(spacing: 14) {
                JcIcon("antenna.radiowaves.left.and.right.slash", size: 40, weight: .light)
                    .foregroundStyle(JcTheme.amber)
                Text("Turn on Bluetooth")
                    .font(JcText.body.weight(.semibold))
                Text("Jarvis devices are found and set up over Bluetooth. Boards already on Wi‑Fi still show up here.")
                    .font(.footnote).foregroundStyle(JcTheme.muted)
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
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 8)
        } else {
            HStack(spacing: 10) {
                JcIcon("antenna.radiowaves.left.and.right.slash").foregroundStyle(JcTheme.amber)
                Text("Turn on Bluetooth to find more devices")
                    .font(.subheadline).foregroundStyle(JcTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    private var scannerFooter: some View {
        Toggle("Only Jarvis devices", isOn: Binding(
            get: {
                manager.strictNameMatch && scaleManager.strictNameMatch
                    && esp32Manager.strictNameMatch && ringManager.strictNameMatch
                    && x5Manager.strictNameMatch
            },
            set: { enabled in
                manager.strictNameMatch = enabled
                scaleManager.strictNameMatch = enabled
                esp32Manager.strictNameMatch = enabled
                ringManager.strictNameMatch = enabled
                x5Manager.strictNameMatch = enabled
            }
        ))
        .tint(JcTheme.accent)
        .foregroundStyle(JcTheme.text)
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 12)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

/// Expanding rings, like a radar sweep — visibly different from the plain spinner so
/// "scanning" and "Bluetooth is off" never look alike.
private struct ScanRadar: View {
    /// Overall footprint; the rings grow to fill it.
    var size: CGFloat = 140
    /// The rings exist only while the Devices tab is on screen: every tab stays mounted, so a
    /// radar behind another tab ticked SwiftUI every frame for as long as the app was open.
    @State private var onScreen = false

    var body: some View {
        ZStack {
            if onScreen { ScanRadarRings(size: size) }
            JcIcon("dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.2, weight: .light))
                .foregroundStyle(JcTheme.accent)
        }
        .frame(width: size, height: size)
        .onTabVisibilityChange(.devices) { onScreen = $0 }
    }
}

private struct ScanRadarRings: View {
    let size: CGFloat
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(JcTheme.accent.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size * 0.29, height: size * 0.29)
                    .scaleEffect(animate ? 3.2 : 1)
                    .opacity(animate ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                               value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

private struct ScaleCard: View {
    let scale: DiscoveredScale
    var connected = false
    var lastSeen: Date? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScaleSceneView(state: .idle, weightText: nil, entrance: false,
                           presentation: .card)
                .environment(\.sceneStills, true)
                .frame(width: 275, height: 190)
                .offset(x: 116, y: -4)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                Text(WearableNames.shared.name(WearableKeepAlive.scale, fallback: scale.name.isEmpty ? "ESF551" : scale.name))
                    .font(JcText.title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 190, alignment: .leading)
                Text("Etekcity body scale")
                    .font(.caption).foregroundStyle(JcTheme.muted).padding(.top, 3)
                Spacer()
                if connected {
                    MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                               tint: JcTheme.success)
                } else if scale.rssi == 0 {
                    // Remembered, not advertising: say so rather than "Known", which read as a link.
                    DisconnectedPill()
                } else {
                    MetricPill(icon: "antenna.radiowaves.left.and.right", label: "Signal",
                               value: "\(scale.rssi) dBm", tint: signalTint)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .lastSeenCorner(lastSeen, visible: !connected && scale.rssi == 0)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous).strokeBorder(JcTheme.border, lineWidth: 1))
    }

    private var signalTint: Color {
        switch scale.rssi {
        case 0: return JcTheme.accent
        case (-68)...: return JcTheme.success
        case (-82)..<(-68): return .orange
        default: return JcTheme.danger
        }
    }
}

// MARK: - Card

private struct BottleCard: View {
    static let cardHeight: CGFloat = 190
    /// How far the model runs past the card's bottom edge.
    static let bleed: CGFloat = 46

    let bottle: DiscoveredWearable
    var connected = false
    /// When the bottle was last in range, for the offline corner note.
    var lastSeen: Date? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if BottleProtocol.hasModel(forName: bottle.name) {
                // Whole bottle, leaning, sitting in the right of the card and running a
                // little past its bottom edge — the camera does the placing, so nothing
                // is cropped mid-body.
                BottleSceneView(spin: true, tilt: -0.16,
                                cameraX: -0.31, cameraY: 0.16, cameraZ: 2.6)
                    .environment(\.sceneStills, true)
                    .frame(height: Self.cardHeight + Self.bleed)
                    .padding(.bottom, -Self.bleed)
            } else {
                HStack {
                    Spacer()
                    JcIcon("antenna.radiowaves.left.and.right", size: 34, weight: .light)
                        .foregroundStyle(JcTheme.muted)
                        .padding(.trailing, 34)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(WearableNames.shared.name(WearableKeepAlive.bottle, fallback: bottle.name.isEmpty ? "Unnamed" : bottle.name))
                    .font(JcText.title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 190, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if connected {
                        MetricPill(icon: "checkmark.circle.fill", label: "Status", value: "Connected",
                                   tint: JcTheme.success)
                    } else if bottle.rssi == 0 {
                        // Remembered, not advertising. Its 0 read as "0 dBm" with full
                        // green bars — a link it didn't have.
                        DisconnectedPill()
                    } else {
                        MetricPill(icon: "antenna.radiowaves.left.and.right",
                                   label: "Signal",
                                   value: "\(bottle.rssi) dBm",
                                   tint: signalTint)
                        SignalBars(rssi: bottle.rssi)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        .lastSeenCorner(lastSeen, visible: !connected && bottle.rssi == 0)
        .background(JcTheme.glassFill,
                    in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }

    private var signalTint: Color {
        switch bottle.rssi {
        case (-68)...:      return JcTheme.success
        case (-82)..<(-68): return .orange
        default:            return JcTheme.danger
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
                    .fill(i <= level ? JcTheme.accent : JcTheme.muted.opacity(0.25))
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
            JcIcon("antenna.radiowaves.left.and.right.slash", size: 26, weight: .light)
                .foregroundStyle(JcTheme.muted)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(JcText.body.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
            }

            Spacer(minLength: 8)

            JcSmallAction("Connect", busy: busy, action: connect)
        }
        .padding(JcUnified.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
    }

    private var subtitle: String {
        guard let seen = DisconnectedPill.lastSeenNote(entry.lastSeen) else { return "Not found" }
        let signal = entry.lastRSSI.map { " · \($0) dBm" } ?? ""
        return "Not found · \(seen)\(signal)"
    }
}
