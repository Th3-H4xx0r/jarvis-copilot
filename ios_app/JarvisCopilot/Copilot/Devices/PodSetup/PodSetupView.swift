import SwiftUI

/// Full-screen camera that looks for a Jarvis device setup code.
struct PodScanView: View {
    let onFound: (PodSetupCode) -> Void
    /// Closing goes through the presenter's binding: `dismiss` from inside a camera
    /// cover didn't close it.
    let onClose: () -> Void
    @State private var scanner = CameraQRScanner()
    @State private var hint: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The UIKit preview must never take the taps meant for the close button.
            QRPreview(scanner: scanner).ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    GlassIconButton(symbol: "xmark", size: 44, iconSize: 17) {
                        scanner.stop()
                        onClose()
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                Text(hint ?? scanner.failureMessage ?? "Point the camera at the QR code on your Jarvis device")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .jcLiquidGlass(in: Capsule())
            }
            .padding(20)
        }
        .onAppear {
            scanner.start { raw in
                if let code = PodSetupCode.parse(raw) {
                    scanner.stop()
                    onFound(code)
                } else {
                    hint = "That isn't a Jarvis device code"
                }
            }
        }
        .onDisappear { scanner.stop() }
    }
}

/// The pairing modal: the orb, a glass card holding the vertical stepper, and a pinned
/// Done button once the pod is online.
struct PodSetupView: View {
    @State private var flow: PodSetupFlow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false
    @FocusState private var passwordFocused: Bool
    var onFinished: () -> Void = {}

    init(code: PodSetupCode, onFinished: @escaping () -> Void = {}) {
        _flow = State(initialValue: PodSetupFlow(code: code))
        self.onFinished = onFinished
    }

    init(flow: PodSetupFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    GlassCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(PodSetupFlow.Step.allCases) { step in
                                row(step, last: step == .done)
                            }
                        }
                    }
                    if flow.finished { tips }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(JcTheme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if flow.finished {
                    GlassButton(title: "Done", full: true) { close() }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if flow.finished || flow.failedStep != nil { close() } else { confirmCancel = true }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(JcTheme.text)
                    }
                    .accessibilityLabel("Cancel")
                }
            }
            .confirmationDialog("Stop setting up the pod?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Stop setup", role: .destructive) { close() }
                Button("Keep going", role: .cancel) {}
            }
        }
        .task { await flow.start() }
        .onChange(of: flow.focusPassword) { _, focus in if focus { passwordFocused = true } }
    }

    private func close() {
        let finished = flow.finished
        Task {
            if !finished { await flow.cancel() }
            if finished { onFinished() }
        }
        dismiss()
    }

    // MARK: Hero

    private var orbState: VoiceState {
        if flow.finished { return .idle }
        if flow.failedStep != nil { return .error }
        return flow.statuses[.pair] == .active ? .thinking : .connecting
    }

    private var headline: String {
        if flow.finished { return "\(flow.code.podName) is ready" }
        if flow.failedStep != nil { return "Something needs a hand" }
        if flow.statuses[.wifi] == .active { return "Pick its Wi-Fi" }
        return "Setting up \(flow.code.podName)"
    }

    private var subline: String {
        if flow.finished { return "Paired with Jarvis and online." }
        if let step = flow.failedStep, case .failed(let message) = flow.statuses[step] { return message }
        if flow.statuses[.wifi] == .active { return "The pod joins this network to reach Jarvis." }
        return "Keep the pod close to your phone."
    }

    private var hero: some View {
        VStack(spacing: 14) {
            VoiceOrb(state: orbState, amplitude: 0, size: 150)
                .frame(height: 150)
                .padding(.top, 4)
            VStack(spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.center)
                Text(subline)
                    .font(.subheadline)
                    .foregroundStyle(flow.failedStep != nil ? JcTheme.danger : JcTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .animation(.easeInOut(duration: 0.25), value: headline)
        }
        .frame(maxWidth: .infinity)
    }

    private var tips: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Try it").font(.headline).foregroundStyle(JcTheme.text)
                tip("waveform", "Say \u{201C}Jarvis\u{201D}, or tap the pod, and ask anything.")
                tip("sparkles.rectangle.stack", "\u{201C}Show me today's NVIDIA chart\u{201D} puts it on the screen.")
                tip("house", "\u{201C}Make me a home page with the weather\u{201D} designs its home screen.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(JcTheme.accent).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(JcTheme.muted)
        }
    }

    // MARK: Stepper

    private func detailText(_ step: PodSetupFlow.Step, _ status: PodSetupFlow.Status) -> String? {
        if status == .pending { return nil }
        if let text = flow.detail[step] { return text }
        switch (step, status) {
        case (.send, .done): return "Wi-Fi, server and pairing code sent"
        case (.send, .active): return "Sending to the pod…"
        default: return nil
        }
    }

    @ViewBuilder
    private func row(_ step: PodSetupFlow.Step, last: Bool) -> some View {
        let status = flow.statuses[step] ?? .pending
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker(step, status)
                if !last {
                    Capsule()
                        .fill(status == .done ? JcTheme.accent.opacity(0.55) : Color.white.opacity(0.10))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status == .pending ? JcTheme.muted : JcTheme.text)
                if case .failed(let message) = status {
                    Text(message).font(.subheadline).foregroundStyle(JcTheme.danger)
                    Button("Try again") { Task { await flow.retry() } }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                        .padding(.top, 6)
                } else if let text = detailText(step, status) {
                    Text(text).font(.subheadline).foregroundStyle(JcTheme.muted).lineLimit(2)
                }
                if step == .wifi && status == .active {
                    wifiPicker.padding(.top, 10)
                }
            }
            .padding(.top, 3)
            .padding(.bottom, last ? 0 : 18)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func marker(_ step: PodSetupFlow.Step, _ status: PodSetupFlow.Status) -> some View {
        ZStack {
            switch status {
            case .pending:
                Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5)
                Text("\(step.rawValue + 1)").font(.caption.weight(.bold)).foregroundStyle(JcTheme.muted)
            case .active:
                Circle().fill(JcTheme.accent.opacity(0.14))
                Circle().strokeBorder(JcTheme.accent, lineWidth: 1.5)
                ProgressView().controlSize(.mini).tint(JcTheme.accent)
            case .done:
                Circle().fill(JcTheme.accent)
                Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(JcTheme.bg)
            case .failed:
                Circle().fill(JcTheme.danger.opacity(0.18))
                Circle().strokeBorder(JcTheme.danger, lineWidth: 1.5)
                Image(systemName: "exclamationmark").font(.caption.weight(.heavy)).foregroundStyle(JcTheme.danger)
            }
        }
        .frame(width: 26, height: 26)
    }

    private var wifiPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if flow.scanning && flow.networks.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(JcTheme.accent)
                    Text("Looking for networks…").font(.subheadline).foregroundStyle(JcTheme.muted)
                }
                .padding(.vertical, 6)
            }
            ForEach(flow.networks) { network in
                let selected = flow.selectedSSID == network.ssid
                Button {
                    flow.selectedSSID = network.ssid
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi", variableValue: signal(network.rssi))
                            .foregroundStyle(selected ? JcTheme.accent : JcTheme.muted)
                            .frame(width: 22)
                        Text(network.ssid).foregroundStyle(JcTheme.text).lineLimit(1)
                        Spacer()
                        if network.secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(JcTheme.muted) }
                        if selected { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(JcTheme.accent) }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                    .background(selected ? JcTheme.accent.opacity(0.12) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? JcTheme.accent.opacity(0.6) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if flow.selectedIsSecure && flow.selectedSSID != nil {
                SecureField("Wi-Fi password", text: $flow.password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(JcTheme.text)
                    .submitLabel(.go)
                    .onSubmit { if flow.canSubmitWifi { Task { await flow.submitWifi() } } }
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await flow.loadNetworks() } }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                Spacer()
                Button("Continue") { Task { await flow.submitWifi() } }
                    .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    .disabled(!flow.canSubmitWifi)
                    .opacity(flow.canSubmitWifi ? 1 : 0.5)
            }
            .padding(.top, 4)
        }
    }

    private func signal(_ rssi: Int) -> Double {
        min(1, max(0.1, Double(rssi + 90) / 40))
    }
}
