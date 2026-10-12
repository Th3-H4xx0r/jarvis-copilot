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
                battery
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
            GlassQuietLabel("This device")
            GlassGroup {
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

    // MARK: Battery

    /// What the app costs, from iOS's own daily energy report.
    ///
    /// The app deliberately holds a silent audio session so Jarvis can reach the
    /// phone without a push hop, which means it is never suspended and "Background"
    /// in iOS Settings reads as most of a day. That is expected; what matters is
    /// how much CPU it burns while it sits there, and this is the only place that
    /// number is visible without a Mac, a cable and root.
    @ViewBuilder
    private var battery: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Battery")
            GlassGroup {
                if let snapshot = EnergyReport.load() {
                    InfoRow(symbol: "bolt.fill", title: "CPU while running",
                            value: cpuRateText(snapshot))
                    InfoRow(symbol: "moon.fill", title: "Background",
                            value: hours(snapshot.backgroundSeconds))
                    InfoRow(symbol: "speaker.slash.fill", title: "Of that, silent audio",
                            value: hours(snapshot.backgroundAudioSeconds), last: true)
                } else {
                    InfoRow(symbol: "clock", title: "No report yet",
                            value: "iOS sends one daily", last: true)
                }
            }
            Text("iOS measures this itself and delivers it about once a day, so a "
               + "change here takes a day to show up. Lower CPU for the same "
               + "background hours is the win.")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 4)
        }
    }

    private func cpuRateText(_ snapshot: EnergyReport) -> String {
        guard let rate = snapshot.cpuSecondsPerHour else { return "\u{2014}" }
        return String(format: "%.0f s / hour", rate)
    }

    private func hours(_ seconds: Double) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Assistant")
            GlassGroup {
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
                    JcIcon("bell.slash.fill")
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
            GlassQuietLabel("More")
            GlassGroup {
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
                    WidgetCreatorPage()
                } label: {
                    GlassRow(symbol: "square.grid.2x2.fill", title: "Widget creator",
                             subtitle: "Home Screen, Lock Screen and Control Center")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SpeechEngineScreen()
                } label: {
                    GlassRow(symbol: "waveform", title: "Speech engine",
                             subtitle: "Who turns speech into text: Soniox or the current flow")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ContextCompactionScreen()
                } label: {
                    GlassRow(symbol: "gauge.with.needle", title: "Auto-compact",
                             subtitle: "When long chats get summarized, per model")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    PromptCacheScreen()
                } label: {
                    GlassRow(symbol: "clock.arrow.circlepath", title: "Keep prompts cached",
                             subtitle: "How long the shared prompt stays warm between messages")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    WebBrowserSettingsScreen()
                } label: {
                    GlassRow(symbol: "globe", title: "Web & browser",
                             subtitle: "Extraction model, browser engine, stealth fallback")
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
        GlassGroup {
            GlassRow(symbol: "rectangle.portrait.and.arrow.right",
                     title: "Unpair this device",
                     last: true, danger: true) {
                confirmUnpair = true
            }
        }
    }
}

/// A toggle row styled to match `GlassRow` — circular icon chip + switch.
struct SwitchRow: View {
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
                .tint(JcTheme.accent)
        }
    }
}

/// A row that only reports a number — the Battery section's whole vocabulary.
private struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String
    var last: Bool = false

    var body: some View {
        GlassRow(symbol: symbol, title: title, last: last) {
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
        }
    }
}

// MARK: - Auto-compact

/// The server's auto-compact settings (`/api/compression/config`) — the same
/// `compression:` keys the web's Settings → Auto-compact block edits — and the
/// trigger for the chat's model. Nothing here is stored on the phone.
struct CompactionSettings: Equatable, Sendable {
    var enabled = true
    var percent = 50
    /// `max_context_tokens`: 0 = no cap, the percentage alone decides.
    var cap = 0
    var minPercent = 10
    var maxPercent = 95
    var floorTokens = 64_000
    var minCapTokens = 16_000
    var fallbackContextLength = 256_000
    var model = ""
    /// 0 when the server doesn't know the model's window.
    var contextLength = 0

    static func from(_ d: [String: Any]) -> CompactionSettings {
        var out = CompactionSettings()
        out.apply(d)
        return out
    }

    /// A GET, or a PUT's reply.
    mutating func apply(_ d: [String: Any]) {
        let c = d.dict("config") ?? [:]
        if let v = c.bool("enabled") { enabled = v }
        if let v = c.int("threshold_percent") { percent = v }
        if let v = c.int("max_context_tokens") { cap = v }
        let l = d.dict("limits") ?? [:]
        if let v = l.int("min_percent") { minPercent = v }
        if let v = l.int("max_percent") { maxPercent = v }
        if let v = l.int("floor_tokens") { floorTokens = v }
        if let v = l.int("min_cap_tokens") { minCapTokens = v }
        if let v = l.int("fallback_context_length"), v > 0 { fallbackContextLength = v }
        let p = d.dict("preview") ?? [:]
        if let v = p.string("model") { model = v }
        if let v = p.int("context_length") { contextLength = v }
    }

    /// Mirrors `compute_threshold_tokens` (agent/context_compressor.py): the share
    /// of the window, never below the floor, never above `maxPercent` of it, and
    /// never above the cap when one is set.
    func trigger(contextLength ctx: Int, percent pct: Int, cap: Int) -> Int {
        let window = ctx > 0 ? ctx : fallbackContextLength
        var tokens = min(max(window * pct / 100, floorTokens), window * maxPercent / 100)
        if cap > 0 { tokens = min(tokens, cap) }
        return tokens
    }

    var trigger: Int { trigger(contextLength: contextLength, percent: percent, cap: cap) }

    var readout: String {
        guard enabled else {
            return "Off — chats are never summarized, so a long one ends with a context-limit "
                + "error when it fills the window."
        }
        let tokens = trigger
        let name = model.isEmpty ? "the default model" : model
        var line = contextLength > 0
            ? "Compacts at \(tokens.formatted()) of \(contextLength.formatted()) tokens for \(name)"
            : "Compacts at \(tokens.formatted()) tokens for \(name) (its window isn't known, "
                + "so \(fallbackContextLength.formatted()) is assumed)"
        let window = contextLength > 0 ? contextLength : fallbackContextLength
        if cap > 0 && tokens == cap {
            line += " — held down by the token cap"
        } else if tokens == floorTokens && window * percent / 100 < tokens {
            line += " — never below \(floorTokens.formatted())"
        }
        return line + "."
    }
}

struct CompactionAPI: Sendable {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    /// The settings, with the trigger worked out for `model` (the server's default
    /// model when nil).
    func load(model: String?, provider: String?) async throws -> [String: Any] {
        var query: [String: String] = [:]
        if let model, !model.isEmpty { query["model"] = model }
        if let provider, !provider.isEmpty { query["provider"] = provider }
        return try await api.get("/api/compression/config", query: query).object()
    }

    /// PUT a patch (just the keys that changed); the reply is the server's view.
    func save(_ patch: [String: Any]) async throws -> [String: Any] {
        try await api.put("/api/compression/config", json: patch).object()
    }
}

/// The auto-compact settings on screen. Every change shows at once and is PUT at
/// once; a refusal puts back what the server holds and says why — the same shape
/// as `SpeechEngineStore`.
@MainActor
@Observable
final class CompactionStore {
    static let shared = CompactionStore()

    private(set) var settings = CompactionSettings()
    private(set) var loaded = false
    private(set) var error = ""

    private let api: CompactionAPI
    /// Whose window the readout is for: the model the chat tab is set to.
    private let selection: ModelSelection

    init(api: CompactionAPI = CompactionAPI(), selection: ModelSelection = .shared) {
        self.api = api
        self.selection = selection
    }

    func load() async {
        do {
            settings = CompactionSettings.from(
                try await api.load(model: selection.model(for: .chat), provider: selection.provider(for: .chat)))
            loaded = true
            error = ""
        } catch {
            self.error = apiErrorLine(error)
        }
    }

    func setEnabled(_ on: Bool) async {
        guard settings.enabled != on else { return }
        let old = settings.enabled
        settings.enabled = on
        await commit(["enabled": on]) { $0.enabled = old }
    }

    func setPercent(_ percent: Int) async {
        let value = min(max(percent, settings.minPercent), settings.maxPercent)
        guard value != settings.percent else { return }
        let old = settings.percent
        settings.percent = value
        await commit(["threshold_percent": value]) { $0.percent = old }
    }

    /// 0 removes the cap.
    func setCap(_ tokens: Int) async {
        let value = max(0, tokens)
        guard value != settings.cap else { return }
        let old = settings.cap
        settings.cap = value
        await commit(["max_context_tokens": value]) { $0.cap = old }
    }

    /// Save one change already on screen. A refusal puts back ONLY that field.
    private func commit(_ patch: [String: Any], revert: (inout CompactionSettings) -> Void) async {
        var body = patch
        body["model"] = selection.model(for: .chat) ?? ""
        body["provider"] = selection.provider(for: .chat) ?? ""
        do {
            settings.apply(try await api.save(body))
            error = ""
        } catch {
            revert(&settings)
            self.error = apiErrorLine(error)
        }
    }
}

/// Settings → Auto-compact: when a long chat's earlier turns get summarized, as
/// a share of the current model's window, plus an optional token cap. Saved as
/// each change is made.
struct ContextCompactionScreen: View {
    @State private var store = CompactionStore.shared
    @State private var percentDraft: Double = 50
    @State private var capDraft = ""
    @FocusState private var capFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                onOff
                share
                capSection
                if !store.error.isEmpty {
                    Text(store.error)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen("Auto-compact")
        .task { await store.load(); syncDrafts() }
        .refreshable { await store.load(); syncDrafts() }
    }

    /// The saved settings with the share being dragged, so the readout moves
    /// with the slider before anything is saved.
    private var shown: CompactionSettings {
        var s = store.settings
        s.percent = Int(percentDraft.rounded())
        return s
    }

    private var onOff: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Auto-compact")
            GlassGroup {
                SwitchRow(symbol: "gauge.with.needle", title: "Compact long chats",
                          subtitle: "Summarize the earlier turns when a chat fills up, so it can go on",
                          isOn: store.settings.enabled, last: true) { on in
                    Task { await store.setEnabled(on) }
                }
            }
            LiveSettingsNote("It follows the model: a 1M-token model at 50% compacts at 500K, a 200K "
                           + "model at 100K. Applies to chat, voice and messaging from the next turn.")
        }
    }

    private var share: some View {
        let s = shown
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("When")
            GlassGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Share of the window")
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                        Spacer()
                        Text("\(s.percent)%")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(JcTheme.accent)
                    }
                    Slider(value: $percentDraft,
                           in: Double(s.minPercent)...Double(max(s.minPercent + 1, s.maxPercent)),
                           step: 1) { editing in
                        guard !editing else { return }
                        let value = Int(percentDraft.rounded())
                        Task { await store.setPercent(value); syncDrafts() }
                    }
                    .tint(JcTheme.accent)
                }
                .padding(14)
                .disabled(!s.enabled)
                .opacity(s.enabled ? 1 : 0.5)
            }
            LiveSettingsNote(s.readout)
        }
    }

    private var capSection: some View {
        let s = store.settings
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Token cap")
            GlassGroup {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("No cap — percentage only", text: $capDraft)
                        .keyboardType(.numberPad)
                        .focused($capFocused)
                        .jcFieldStyle()
                    HStack(spacing: 10) {
                        GlassButton(title: "Save", action: capDraftValue == nil || capDraftValue == s.cap
                                    ? nil : { saveCap() })
                        GlassButton(title: "Remove", ghost: true, action: s.cap > 0 ? {
                            capDraft = ""
                            saveCap()
                        } : nil)
                    }
                }
                .padding(14)
                .disabled(!s.enabled)
                .opacity(s.enabled ? 1 : 0.5)
            }
            LiveSettingsNote("Optional. Compact by this many tokens at the latest, whatever the window — "
                           + "it bounds what a 1M-token model re-reads each step. At least "
                           + "\(s.minCapTokens.formatted()); empty for none.")
        }
    }

    /// The typed cap: empty is 0 (none); nil when it isn't a number.
    private var capDraftValue: Int? {
        let digits = capDraft.filter { !$0.isWhitespace && $0 != "," && $0 != "." }
        return digits.isEmpty ? 0 : Int(digits)
    }

    private func saveCap() {
        capFocused = false
        guard let value = capDraftValue else { return }
        Task { await store.setCap(value); syncDrafts() }
    }

    private func syncDrafts() {
        percentDraft = Double(store.settings.percent)
        capDraft = store.settings.cap > 0 ? String(store.settings.cap) : ""
    }
}
