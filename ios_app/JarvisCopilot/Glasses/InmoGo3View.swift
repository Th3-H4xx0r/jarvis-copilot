import SwiftUI

// MARK: - Card

/// The glasses' card in the Devices list. Always shown — it is how the glasses are found
/// before they have ever been paired — and lit up while the glasses are connected.
///
/// "Connected" is `GlassesConnectionStatus`: the control link, the same rule the glasses' page
/// uses; audio on its own reads "Audio only".
struct GlassesCard: View {
    let route: GlassesRouteState
    /// Nil until the glasses have been on the route once (or since they were forgotten).
    let lastSeen: Date?
    @ObservedObject private var session = InmoSession.shared

    init(route: GlassesRouteState, lastSeen: Date?) {
        self.route = route
        self.lastSeen = lastSeen
    }

    private var status: GlassesConnectionStatus { .of(control: session.state, audio: route.connected) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack {
                Spacer()
                // Turning costs a continuous render; a card for glasses never seen stays still.
                GlassesSceneView(spin: route.connected || lastSeen != nil || status.lit, lit: status.lit)
                    .environment(\.sceneStills, true)
                    .frame(width: 124, height: 124)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(InmoGo3.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("INMO GO3 smart glasses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if status == .offline, lastSeen == nil {
                        MetricPill(icon: "link", label: "Status", value: "Not paired yet", tint: .secondary)
                    } else {
                        MetricPill(icon: status.symbol, label: "Status", value: status.title,
                                   tint: status == .offline || status == .audioOnly ? .secondary : status.tint)
                    }
                    if status == .connected, let battery = session.status.battery {
                        MetricPill(icon: Self.batterySymbol(battery), label: "Battery", value: "\(battery)%",
                                   tint: battery <= 20 ? JcTheme.danger : JcTheme.success)
                    } else if route.connected {
                        MetricPill(icon: "speaker.wave.2.fill", label: "Audio",
                                   value: route.speakers ? "Glasses" : "iPhone", tint: JcTheme.accent)
                    }
                }
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        // Audio on the route means "now", not "last seen".
        .lastSeenCorner(lastSeen, visible: status == .offline)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Page

/// The glasses' page, laid out like iOS's AirPods page: the glasses and their status up top,
/// the four things you reach for, the gallery, then short rows into everything else. Day-to-day
/// controls live here; the protocol and research tools sit under About › Advanced.
struct InmoGo3View: View {
    private let link = GlassesAudioLink.shared
    @ObservedObject private var session = InmoSession.shared
    @ObservedObject private var actions = GlassesActions.shared
    @State private var renaming = false
    @State private var confirmForget = false
    @State private var connectError: String?
    @State private var showOwnerSetup = false

    private var route: GlassesRouteState { link.state }
    private var known: Bool { link.known }
    private var name: String { InmoGo3.name }
    private var stepsDone: Int { [known, link.heardSpeakers, link.usedMic].filter { $0 }.count }
    private var status: GlassesConnectionStatus { .of(control: session.state, audio: route.connected) }
    private var ready: Bool { status == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if stepsDone < 3 { setupRow }
                // Only while the glasses are unknown: once known, a headset on the route
                // (AirPods, say) is not an invitation to re-pick them.
                if !known, let headset = route.otherHeadset { claimSection(headset) }
                quickActions
                InmoMediaView()
                settingsGroup
                featuresGroup
                aboutGroup
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .tint(JcTheme.accent)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            WearableToolbarButton(title: "Refresh", icon: "arrow.clockwise") { link.refresh() }
            WearableMoreMenu(onRename: { renaming = true }, extra: {
                if known {
                    Button("Forget these glasses", jcIcon: "xmark.circle", role: .destructive) { confirmForget = true }
                }
            })
        }
        .onAppear { link.refresh(); actions.clear() }
        // Outside the status switch: the setup page stays put while the status changes under it.
        .navigationDestination(isPresented: $showOwnerSetup) { GlassesOwnerSetupPage() }
        .wearableRename(isPresented: $renaming, current: name) {
            WearableNames.shared.rename(WearableKeepAlive.glasses, to: $0)
        }
        .alert("Forget these glasses?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { link.forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jarvis stops treating this headset as your GO3. Unpair it in Settings › Bluetooth to disconnect it.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            // Closer than the card's 4.2: the frame is wide, and the field of view is vertical.
            GlassesSceneView(spin: true, entrance: true, lit: status.lit, cameraDistance: 3.4)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
            Text(name)
                .font(.title.weight(.bold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            HStack(spacing: 8) {
                GlassesChip(text: statusText, symbol: status.symbol, tint: status.tint)
                if ready, let battery = session.status.battery {
                    GlassesChip(text: "\(battery)%", symbol: GlassesCard.batterySymbol(battery),
                                tint: battery <= 20 ? JcTheme.danger : JcTheme.success)
                }
                if route.connected {
                    GlassesChip(text: route.speakers ? "Glasses audio" : "iPhone audio", symbol: "speaker.wave.2.fill")
                }
            }
            heroAction
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var statusText: String {
        if status == .offline {
            if !known { return "Not paired yet" }
            if let note = DisconnectedPill.lastSeenNote(WearableIdentity.lastSeen(WearableKeepAlive.glasses)) {
                return "Not connected · \(note)"
            }
        }
        return status.title
    }

    /// Connect when the control link is down; the pairing key when it needs one. Errors are put
    /// in plain words here; the raw text is under About › Advanced.
    @ViewBuilder private var heroAction: some View {
        switch status {
        case .setupNeeded:
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button { showOwnerSetup = true } label: { Label("Add pairing key", jcIcon: "key.fill") }
                        .buttonStyle(.jcGlass(tint: JcTheme.amber))
                    Button { connect() } label: { Label("Connect", jcIcon: "dot.radiowaves.left.and.right") }
                        .buttonStyle(.jcGlass)
                }
                Text(Self.plain(connectError ?? session.lastError) ?? "Jarvis needs your glasses' pairing key once.")
                    .font(.caption).foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        case .offline, .audioOnly:
            VStack(spacing: 6) {
                Button { connect() } label: { Label("Connect", jcIcon: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.jcGlass)
                if let message = Self.plain(connectError ?? session.lastError) {
                    Text(message).font(.caption).foregroundStyle(JcTheme.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        case .connecting, .connected:
            EmptyView()
        }
    }

    /// The session's errors are written for debugging; the main page says what to do.
    static func plain(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("bluetooth is unavailable") || lower.contains("bluetooth is off") || lower.contains("allow jarvis") {
            return "Turn on Bluetooth and allow Jarvis to use it."
        }
        if lower.contains("unlock") { return "Unlock your iPhone once, then tap Connect." }
        if lower.contains("owner identity") || lower.contains("identity") { return "Jarvis needs your glasses' pairing key once." }
        return "Couldn't reach the glasses. Make sure they're on and nearby, close the INMO app, then try again."
    }

    private func connect() {
        connectError = nil
        Task {
            do { try await session.ensureConnected(force: true) }
            catch { connectError = error.localizedDescription }
        }
    }

    // MARK: Setup

    private var setupRow: some View {
        GlassGroup {
            GlassesLinkRow(symbol: "checklist", title: "Finish setting up", value: "\(stepsDone) of 3", last: true) {
                GlassesSetupPage()
            }
        }
    }

    /// The GO3's Bluetooth name is a guess until one is paired, so an unrecognised headset
    /// is offered rather than assumed.
    private func claimSection(_ headset: GlassesAudioPort) -> some View {
        GlassesSection("Are these your glasses?") {
            GlassRow(symbol: "headphones", title: headset.name,
                     subtitle: "Connected over Bluetooth — only if it's your GO3 under another name",
                     subtitleLineLimit: 2, last: true) {
                Button("Use") { link.claim(headset) }.buttonStyle(.jcGlass(compact: true))
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                quick("Talk", "mic.fill") { Task { await InmoAIChannel.shared.startFromPhone() } }
                quick("Photo", "camera.fill") { actions.run("glasses_camera_open") }
                quick("Video", "video.fill") { actions.run("glasses_video_open") }
                NavigationLink { GlassesTeleprompterPage() } label: { quickLabel("Prompter", "text.alignleft") }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.4)
            }
            GlassesActionStatus()
        }
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { quickLabel(title, icon) }
            .buttonStyle(.plain)
            .disabled(!ready)
            .opacity(ready ? 1 : 0.4)
    }

    private func quickLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            JcIcon(icon, size: 22)
                .foregroundStyle(JcTheme.accent)
                .frame(width: 62, height: 62)
                .jcLiquidGlass(in: Circle())
            Text(title).font(.caption.weight(.medium)).foregroundStyle(JcTheme.text)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    private var settingsGroup: some View {
        GlassesSection("Settings") {
            GlassesLinkRow(symbol: "sun.max", title: "Display & sound",
                           value: ready ? session.status.brightness.map { "\($0)%" } : nil) { GlassesDisplaySoundPage() }
            GlassesLinkRow(symbol: "hand.tap", title: "Controls") { GlassesControlsPage() }
            GlassesLinkRow(symbol: "sparkles", title: "Talking to Jarvis",
                           value: InmoAIChannel.shared.enabled ? "On" : "Off") { GlassesTalkingPage() }
            GlassesLinkRow(symbol: "bell.badge", title: "Notifications",
                           value: InmoSession.notificationsEnabled ? "On" : "Off", last: true) { GlassesNotificationsPage() }
        }
    }

    private var featuresGroup: some View {
        GlassesSection("Features") {
            GlassesLinkRow(symbol: "mic.fill", title: "AI Notes", subtitle: "Record, transcribe and summarise") { GlassesNotesView() }
            GlassesLinkRow(symbol: "globe", title: "Live translation", subtitle: "Translation on the lens") { GlassesTranslateView() }
            GlassesLinkRow(symbol: "captions.bubble", title: "Live captions",
                           subtitle: LiveCaptionsSettingsView.describe(LiveLensBridge.shared.status)) { LiveCaptionsSettingsView() }
            GlassesLinkRow(symbol: "location.north.line.fill", title: "Places & directions",
                           subtitle: "Walking and cycling directions on the lens") { GlassesPlacesView() }
            GlassesLinkRow(symbol: "text.alignleft", title: "Teleprompter", last: true) { GlassesTeleprompterPage() }
        }
    }

    private var aboutGroup: some View {
        GlassGroup {
            GlassesLinkRow(symbol: "info.circle", title: "About these glasses",
                           value: session.status.firmware.map { "v\($0)" }, last: true) { GlassesAboutPage() }
        }
    }
}
