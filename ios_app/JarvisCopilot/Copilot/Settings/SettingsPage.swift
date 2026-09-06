import SwiftUI

/// Settings, ported from `pages/settings_page.dart`.
///
/// The connection hero, the assistant toggles, the navigation rows and the
/// unpair. The two settings screens another area owns (on-device AI, Code
/// Master) are placeholders here — swapping one is a one-line change.
struct SettingsPage: View {
    @State private var store: SettingsStore
    /// A draft rather than a direct binding: clearing the field must be allowed to
    /// stand as empty text while `store.deviceName` falls back to the hardware
    /// label, otherwise the default would keep reappearing under the cursor.
    @State private var deviceNameDraft = ""
    @State private var confirmUnpair = false

    /// See `PairPage.init` — a view's `init` isn't main-actor-isolated, so the
    /// store can't be a default argument.
    ///
    /// The two platform dependencies are named here rather than left implicit:
    /// without them the location switch would record a preference nobody acts on
    /// and the Live Activities switch would leave a running island on the Lock
    /// Screen.
    init(store: SettingsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            SettingsStore(location: BackgroundLocationService.shared,
                          liveActivity: LiveActivityCoordinator.shared)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                hero
                identity
                assistant
                navigation
                danger
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen("Settings")
        .onAppear {
            deviceNameDraft = store.deviceName
            // The permission can be revoked in iOS Settings while we are
            // backgrounded, so re-read it every time the screen comes up.
            store.refreshNotificationStatus()
        }
        .alert("Unpair this device?", isPresented: $confirmUnpair) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) { store.unpair() }
        } message: {
            Text("Stored credentials will be cleared and the app will return to the pair "
               + "screen. The server still has a record until you revoke it from its "
               + "Devices tab.")
        }
    }

    // MARK: Hero

    /// The Voice tab's register without the orb: a quiet status pill, a headline
    /// and one muted line — instead of a gradient card.
    private var hero: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(JcTheme.success).frame(width: 6, height: 6)
                Text(store.deviceName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.text.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.white.opacity(0.045), in: Capsule())
            .padding(.top, 10)
            .padding(.bottom, 18)
            Text("Connected")
                .font(.system(size: 25, weight: .medium))
                .tracking(-0.6)
                .foregroundStyle(JcTheme.text)
            Text(serverHost)
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    /// Just the host: the scheme and path are noise in a status line.
    private var serverHost: String {
        guard !store.serverURL.isEmpty else { return "No server" }
        return URL(string: store.serverURL)?.host ?? store.serverURL
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietLabel("This device")
            GlassGroup(blur: false) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Device name").font(JcText.small).foregroundStyle(JcTheme.muted)
                    TextField("My iPhone", text: $deviceNameDraft)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.text)
                        .textFieldStyle(.plain)
                        .onChange(of: deviceNameDraft) { _, new in store.setDeviceName(new) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: Assistant

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietLabel("Assistant")
            GlassGroup(blur: false) {
                SwitchRow(symbol: "location.fill",
                          title: "Track my location",
                          subtitle: "Background location history for the assistant. "
                                  + "Needs \"Always\"; uses battery.",
                          isOn: store.trackLocation) { on in
                    Task { await store.setTrackLocation(on) }
                }
                SwitchRow(symbol: "rectangle.on.rectangle",
                          title: "Live Activities",
                          subtitle: "Show coding sessions on the Lock Screen / Dynamic Island.",
                          isOn: store.liveActivities) { store.setLiveActivities($0) }
                SwitchRow(symbol: "dot.radiowaves.up.forward",
                          title: "Stay connected in background",
                          subtitle: "Uses a silent audio session so commands don't time out "
                                  + "while the app is backgrounded. Costs some battery; "
                                  + "nothing is audible.",
                          isOn: store.keepalive,
                          last: true) { store.setKeepalive($0) }
            }
            // A refused notification permission is otherwise invisible: coding
            // approvals, deferred actions and the connection banners just never
            // appear, with nothing anywhere saying why.
            if store.notificationsAreOff {
                Label {
                    Text("Notifications are off. Approvals and alerts won't appear — "
                       + "turn them on in iOS Settings → JarvisCopilot.")
                } icon: {
                    Image(systemName: "bell.slash.fill")
                }
                .font(JcText.small)
                .foregroundStyle(JcTheme.amber)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            }
            if let message = store.errorMessage {
                Text(message)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.danger)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietLabel("More")
            GlassGroup(blur: false) {
                NavigationLink {
                    OnDeviceAISettingsPage()
                } label: {
                    GlassRow(symbol: "sparkles", title: "On-device AI",
                             subtitle: "Router, instant commands, local-first")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    CodeMasterSettingsPage()
                } label: {
                    GlassRow(symbol: "chevron.left.forwardslash.chevron.right",
                             title: "Code Master",
                             subtitle: "Coding agents, approvals, models")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    WebViewPage(title: "Server settings", path: "/?panel=settings")
                } label: {
                    GlassRow(symbol: "slider.horizontal.3", title: "Server settings")
                }
                .buttonStyle(.plain)

                // The wearables bridge: which devices Jarvis can see, and the
                // pairing UI that predates this port.
                NavigationLink {
                    BridgeSettingsView()
                } label: {
                    GlassRow(symbol: "antenna.radiowaves.left.and.right",
                             title: "Jarvis bridge",
                             subtitle: "Shared wearables, pairing, bridge mode",
                             last: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var danger: some View {
        GlassGroup(blur: false) {
            GlassRow(symbol: "rectangle.portrait.and.arrow.right",
                     title: "Unpair this device",
                     last: true, danger: true) {
                confirmUnpair = true
            }
        }
    }
}

/// Section label in the Voice page's register: small, spaced, muted — not a
/// bold header competing with the rows.
private struct QuietLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(JcTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.bottom, 10)
    }
}

/// A toggle row styled to match `GlassRow` — circular icon chip + switch.
private struct SwitchRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    let isOn: Bool
    var last: Bool = false
    let onChange: (Bool) -> Void

    var body: some View {
        GlassRow(symbol: symbol, title: title, subtitle: subtitle,
                 subtitleLineLimit: 3, last: last) {
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .tint(JcTheme.primaryBlue)
        }
    }
}
