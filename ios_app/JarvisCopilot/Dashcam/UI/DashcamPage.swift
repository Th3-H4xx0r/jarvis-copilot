import SwiftUI

/// The dashcam's page: status, then Library · Drives · Settings.
struct DashcamPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case library = "Library", drives = "Drives", settings = "Settings"
        var id: String { rawValue }
    }

    @ObservedObject private var sync: DashcamSync = .shared
    @ObservedObject private var wifi: DashcamWiFi = .shared
    @State private var tab: Tab = .library
    @State private var syncing = false
    @State private var live = false
    @State private var reconnecting = false
    @State private var askPassword = false
    @State private var typedPassword = ""
    @State private var reconnectNote: String?
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase

    /// The camera's status is read every 4 s only while this page is really looked at: the keepalive keeps
    /// the app running in the background, where an open page went on reading it.
    private var readsStatus: Bool { onScreen && scenePhase == .active && wifi.onCamera }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if sync.rulesLoaded, let used = sync.phoneBytes {
                    DashcamPhoneSpaceCard(used: used, cap: sync.rules.phoneCapBytes) { tab = .settings }
                }
                if wifi.onCamera { DashcamControlsCard(live: $live) }
                JcSegmented(items: Tab.allCases, selection: $tab, label: \.rawValue)
                .padding(.horizontal, 20)
                switch tab {
                case .library: DashcamLibraryView()
                case .drives: DashcamDrivesView()
                case .settings: DashcamSettingsView()
                }
            }
            .padding(.vertical, 12)
        }
        // Pull to refresh belongs to the page's scroll view; set inside the library it attached to the
        // filter chips' horizontal scroller instead (they dragged down, the list never refreshed).
        .refreshable { if tab == .library { await DashcamLibraryModel.shared.reload() } }
        .background(JcTheme.bg.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            if tab == .library {
                DashcamSelectionBar().padding(.trailing, 16).padding(.bottom, 12)   // just above the tab bar
            }
        }
        .fullScreenCover(isPresented: $live) { DashcamLiveView() }
        .alert("Camera Wi‑Fi password", isPresented: $askPassword) {
            SecureField("Password", text: $typedPassword)
            Button("Join") { let pw = typedPassword; Task { await reconnect(pw) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The password for \(DashcamSetupStore.load()?.ssid ?? "the camera") — it's on the camera's screen. Kept for rejoining on its own.")
        }
        .onAppear { onScreen = true }
        .onChange(of: readsStatus, initial: true) { _, on in sync.watchStatus(on, by: "page") }
        .onDisappear { onScreen = false; sync.watchStatus(false, by: "page") }
        .jcPageChrome(DashcamSetupStore.load()?.displayName ?? "Dashcam")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { DashcamDestinationsView() } label: {
                    JcIcon("externaldrive.badge.icloud", size: 17, weight: .semibold).foregroundStyle(JcTheme.text)
                }
                .accessibilityLabel("Destinations")
            }
        }
    }

    private var header: some View {
        CardGroup {
            Row {
                HStack(spacing: 12) {
                    JcIcon(wifi.onCamera ? "wifi" : "wifi.slash", size: 20)
                        .foregroundStyle(wifi.onCamera ? JcTheme.success : JcTheme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wifi.onCamera ? sync.phase.label : "Away from the camera")
                            .font(.body.weight(.semibold))
                        Text(subtitle).font(.caption).foregroundStyle(JcTheme.muted)
                    }
                    Spacer()
                    if !wifi.onCamera {
                        Button {
                            Task { await reconnect(nil) }
                        } label: {
                            if reconnecting { ProgressView() } else { Text("Reconnect") }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(reconnecting)
                    }
                    Button {
                        syncing = true
                        Task { await sync.syncNow(); syncing = false }
                    } label: {
                        if syncing || sync.passActive { ProgressView() } else { Text("Sync now") }
                    }
                    .buttonStyle(.jcGlass(compact: true))
                    .disabled(!wifi.onCamera || syncing)
                }
            }
            if let d = sync.downloading {
                RowDivider()
                Row { progress("Downloading \(d.name)", d.done, d.total) }
            }
            if let u = sync.uploading {
                RowDivider()
                Row { progress("Uploading to the cloud · \(sync.pendingUploads) waiting", u.done, u.total) }
            }
            if sync.pendingUploads > 0 || !sync.rules.upload {
                RowDivider()
                Row {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sync.rules.upload ? "Cloud backup on" : "Cloud backup paused").font(.callout)
                            if sync.rules.upload, let why = sync.uploadNote {
                                Text(why).font(.caption).foregroundStyle(JcTheme.amber).lineLimit(3)
                            }
                        }
                        Spacer()
                        Button(sync.rules.upload ? "Pause" : "Resume") { sync.setCloudBackup(!sync.rules.upload) }
                            .buttonStyle(.jcGlass(compact: true))
                    }
                }
            }
            if wifi.onCamera {
                RowDivider()
                Row {
                    HStack(spacing: 8) {
                        if let rec = sync.recording {
                            MetricPill(icon: rec ? "record.circle" : "stop.circle", label: "Camera",
                                       value: rec ? "Recording" : "Stopped", tint: rec ? JcTheme.danger : JcTheme.muted)
                        }
                        if let free = sync.sd?.freeBytes {
                            MetricPill(icon: "sdcard", label: "SD free", value: String(format: "%.1f GB", Double(free) / 1e9),
                                       tint: JcMetric.activity)
                        }
                    }
                }
            }
        }
    }

    private func reconnect(_ password: String?) async {
        if password == nil, DashcamSetupStore.password == nil { typedPassword = ""; askPassword = true; return }
        reconnecting = true
        defer { reconnecting = false }
        do {
            try await DashcamWiFi.shared.reconnect(password: password)
            reconnectNote = nil
        } catch {
            reconnectNote = error.localizedDescription
        }
    }

    private var subtitle: String {
        if let reconnectNote, !wifi.onCamera { return reconnectNote }
        return DashcamStatusText.subtitle(lastSync: sync.lastSync, pendingUploads: sync.pendingUploads,
                                          queuedDownloads: sync.queuedDownloads)
    }

    private func progress(_ title: String, _ done: Int64, _ total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: done, countStyle: .file) + " / "
                     + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(JcTheme.muted)
            }
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).tint(JcTheme.accent)
        }
    }
}

/// How much of "Phone space" (Settings → Sync rules) the clips take, as a ring: normal footage and the MP4
/// copies count; events, parking clips and photos always come down and don't. Tapping it opens Settings,
/// where the allowance is set. Black and white; amber only once it's full.
struct DashcamPhoneSpaceCard: View {
    let used: Int64
    let cap: Int64
    var openSettings: () -> Void = {}

    private var fraction: Double { DashcamPhoneSpace.fraction(used: used, cap: cap) }
    private var full: Bool { cap > 0 && used >= cap }
    private var tint: Color { full ? JcTheme.amber : JcTheme.text }

    var body: some View {
        Button(action: openSettings) {
            JcCard(padding: 0) { content }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, JcUnified.pageInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phone space: \(DashcamPhoneSpace.text(used: used, cap: cap) ?? "") used. \(detail)")
        .accessibilityHint("Opens the dashcam settings")
    }

    private var content: some View {
            HStack(spacing: 16) {
                ring
                VStack(alignment: .leading, spacing: 3) {
                    Text("Phone space").font(.system(size: 13, weight: .medium)).foregroundStyle(JcTheme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(DashcamPhoneSpace.gb(used)) GB")
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(JcTheme.text)
                        Text("of \(DashcamPhoneSpace.gb(cap)) GB")
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(full ? JcTheme.amber : JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.muted.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
    }

    private var detail: String {
        if full { return "Full: driving footage waits for room" }
        return "\(DashcamPhoneSpace.gb(max(0, cap - used))) GB left for driving footage"
    }

    /// The share taken, as a ring with the percentage inside.
    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.005, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded(.down)))%")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(JcTheme.text)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
        }
        .frame(width: 64, height: 64)
    }
}
