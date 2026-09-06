import SwiftUI

/// Configuration for the on-device AI layer: tier, per-surface toggles, the
/// active local model, tunables and a debug generate box.
///
/// Port of `mobile_client/lib/pages/ondevice_ai_settings_page.dart`. The model
/// Apple's model needs no download; an MLX row downloads on tap (with a
/// cancellable progress ring) and offers "Delete weights" on long-press.
struct OnDeviceAISettingsPage: View {
    @State private var store: OnDeviceAISettingsStore

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: OnDeviceAISettingsStore? = nil) {
        _store = State(initialValue: store
                       ?? MainActor.assumeIsolated { OnDeviceAISettingsStore() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                availabilityCard
                section("Mode") { tierRows }
                section("Use on-device for") { surfaceRows }
                section("Local model") { modelRows }
                section("Advanced") { advancedRows }
                section("Test") { OnDeviceDebugGenerate(store: store) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen("On-device AI")
        .task { await store.load() }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassSectionLabel(title)
            content()
        }
    }

    // MARK: - Availability

    private var availabilityCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: store.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(store.isReady ? JcTheme.cyan : JcTheme.muted)
                Text(store.availabilitySummary)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }
        }
    }

    // MARK: - Tier

    private var tierRows: some View {
        GlassGroup {
            tierRow(.off, "Off", "Everything runs on the server.")
            tierRow(.routerCommands, "Router + instant commands",
                    "Answer trivial turns + fire device commands locally; escalate the rest.")
            tierRow(.fullLocalFirst, "Full local-first",
                    "Also attempt local tool calls; escalate only when needed.", last: true)
        }
    }

    private func tierRow(_ tier: LocalAiTier, _ title: String, _ subtitle: String,
                         last: Bool = false) -> some View {
        let selected = store.settings.tier == tier
        return GlassRow(symbol: selected ? "largecircle.fill.circle" : "circle",
                        title: title, subtitle: subtitle, subtitleLineLimit: 3,
                        last: last, action: { store.setTier(tier) }) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.cyan)
            }
        }
    }

    // MARK: - Surfaces

    private var surfaceRows: some View {
        GlassGroup {
            OnDeviceSwitchRow(symbol: "bubble.left", title: "Chat",
                              isOn: store.settings.chatEnabled) { store.setChatEnabled($0) }
            OnDeviceSwitchRow(symbol: "waveform", title: "Voice",
                              isOn: store.settings.voiceEnabled,
                              last: true) { store.setVoiceEnabled($0) }
        }
    }

    // MARK: - Models

    private var modelRows: some View {
        GlassGroup {
            if store.models.isEmpty {
                GlassRow(symbol: "cpu", title: "No local models",
                         subtitle: "Apple Foundation Models needs iOS 26 + Apple Intelligence.",
                         subtitleLineLimit: 3, last: true) { EmptyView() }
            } else {
                ForEach(Array(store.models.enumerated()), id: \.element.id) { index, model in
                    let selected = store.activeModelID == model.id
                    let progress = store.downloadProgress[model.id]
                    let downloadable = model.engine == .mlx && !model.installed
                    GlassRow(symbol: model.engine.symbol,
                             title: model.label,
                             subtitle: progress.map { "Downloading… \(Int($0 * 100))%" } ?? model.detail,
                             subtitleLineLimit: 2,
                             last: index == store.models.count - 1,
                             action: model.installed ? { store.selectModel(model) }
                                   : (downloadable && progress == nil) ? { store.download(model) } : nil) {
                        if let progress {
                            Button { store.cancelDownload(model) } label: {
                                ZStack {
                                    ProgressView(value: progress).progressViewStyle(.circular).tint(JcTheme.cyan)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(JcTheme.muted)
                                }
                                .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                        } else if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(JcTheme.cyan)
                        } else if downloadable {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(JcTheme.cyan)
                        }
                    }
                    .opacity(model.installed || downloadable ? 1 : 0.5)
                    .contextMenu {
                        if model.engine == .mlx, model.installed {
                            Button(role: .destructive) { store.delete(model) } label: {
                                Label("Delete weights", systemImage: "trash")
                            }
                        }
                    }
                }
                if let error = store.downloadError {
                    Text(error).font(.caption).foregroundStyle(JcTheme.danger).padding(.horizontal, 14).padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedRows: some View {
        GlassGroup {
            GlassRow(symbol: "arrow.triangle.branch",
                     title: "The model decides escalation",
                     subtitle: "Each turn runs the on-device model to completion; it chooses "
                             + "to answer, act, or hand off to the server. No time limit.",
                     subtitleLineLimit: 4) { EmptyView() }
            OnDeviceSwitchRow(symbol: "exclamationmark.shield",
                              title: "Confirm outward/destructive actions",
                              isOn: store.settings.confirmLocalActions) {
                store.setConfirmLocalActions($0)
            }
            OnDeviceSwitchRow(symbol: "bolt",
                              title: "Device commands short-circuit",
                              isOn: store.settings.commandShortCircuit) {
                store.setCommandShortCircuit($0)
            }
            OnDeviceSwitchRow(symbol: "seal",
                              title: "Show \"on-device\" badge",
                              isOn: store.settings.showBadge,
                              last: true) { store.setShowBadge($0) }
        }
    }
}

/// A toggle row styled like `GlassRow` — the on-device screen's own copy, because
/// `SettingsPage`'s is file-private there.
private struct OnDeviceSwitchRow: View {
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

/// A tiny on-device generate tester: type a prompt, stream the local model's raw
/// output. Bypasses the router — a pure engine check.
private struct OnDeviceDebugGenerate: View {
    @Bindable var store: OnDeviceAISettingsStore

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Prompt the local model…", text: $store.prompt, axis: .vertical)
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { store.runDebugGenerate() }

                HStack {
                    Spacer(minLength: 0)
                    if store.running {
                        GlassButton(title: "Stop", ghost: true) { store.cancelDebugGenerate() }
                    }
                    GlassButton(title: store.running ? "Running…" : "Generate") {
                        store.runDebugGenerate()
                    }
                }

                if !store.output.isEmpty {
                    Text(store.output)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
