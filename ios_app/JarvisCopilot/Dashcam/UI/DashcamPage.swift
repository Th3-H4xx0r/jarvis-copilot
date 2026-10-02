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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if wifi.onCamera { DashcamControlsCard(live: $live) }
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                switch tab {
                case .library: DashcamLibraryView()
                case .drives: DashcamDrivesView()
                case .settings: DashcamSettingsView()
                }
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .fullScreenCover(isPresented: $live) { DashcamLiveView() }
        .alert("Camera Wi‑Fi password", isPresented: $askPassword) {
            SecureField("Password", text: $typedPassword)
            Button("Join") { let pw = typedPassword; Task { await reconnect(pw) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The password for \(DashcamSetupStore.load()?.ssid ?? "the camera") — it's on the camera's screen. Kept for rejoining on its own.")
        }
        .onAppear { sync.watchStatus(wifi.onCamera) }
        .onChange(of: wifi.onCamera) { _, on in sync.watchStatus(on) }
        .onDisappear { sync.watchStatus(false) }
        .navigationTitle(DashcamSetupStore.load()?.displayName ?? "Dashcam")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { DashcamDestinationsView() } label: {
                    JcIcon("externaldrive.badge.icloud", size: 18).foregroundStyle(JcTheme.accent)
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
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
                Row { progress("Uploading", u.done, u.total) }
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
                                       tint: JcTheme.accent)
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
        var parts: [String] = []
        if let last = sync.lastSync { parts.append("Synced \(last.formatted(.relative(presentation: .named)))") }
        if sync.pendingUploads > 0 { parts.append("\(sync.pendingUploads) to upload") }
        if sync.queuedDownloads > 0 { parts.append("\(sync.queuedDownloads) to download") }
        return parts.isEmpty ? "Joins on its own when the camera is on" : parts.joined(separator: " · ")
    }

    private func progress(_ title: String, _ done: Int64, _ total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: done, countStyle: .file) + " / "
                     + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).tint(JcTheme.accent)
        }
    }
}
