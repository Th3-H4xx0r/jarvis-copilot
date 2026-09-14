import SwiftUI

/// Full-screen camera that looks for a Jarvis device setup code.
struct BallScanView: View {
    let onFound: (BallSetupCode) -> Void
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
                if let code = BallSetupCode.parse(raw) {
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

/// The pairing modal: a vertical stepper that drives `BallSetupFlow`.
struct BallSetupView: View {
    @State private var flow: BallSetupFlow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false
    @FocusState private var passwordFocused: Bool
    var onFinished: () -> Void = {}

    init(code: BallSetupCode, onFinished: @escaping () -> Void = {}) {
        _flow = State(initialValue: BallSetupFlow(code: code))
        self.onFinished = onFinished
    }

    init(flow: BallSetupFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(BallSetupFlow.Step.allCases) { step in
                        row(step, last: step == .done)
                    }
                    if flow.finished {
                        Button("Close") { close() }
                            .buttonStyle(.jcGlass(full: true))
                            .padding(.top, 24)
                    }
                }
                .padding(20)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle(flow.code.ballName)
            .navigationBarTitleDisplayMode(.inline)
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
            .confirmationDialog("Stop setting up the ball?", isPresented: $confirmCancel, titleVisibility: .visible) {
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

    // MARK: Stepper row

    @ViewBuilder
    private func row(_ step: BallSetupFlow.Step, last: Bool) -> some View {
        let status = flow.statuses[step] ?? .pending
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker(step, status)
                if !last {
                    Rectangle()
                        .fill(status == .done ? JcTheme.accent.opacity(0.6) : JcTheme.muted.opacity(0.25))
                        .frame(width: 2)
                        .frame(minHeight: 28)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(status == .pending ? JcTheme.muted : JcTheme.text)
                if case .failed(let message) = status {
                    Text(message).font(.subheadline).foregroundStyle(JcTheme.danger)
                    Button("Retry") { Task { await flow.retry() } }
                        .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                } else if let text = flow.detail[step], status != .pending {
                    Text(text).font(.subheadline).foregroundStyle(JcTheme.muted)
                }
                if step == .wifi && status == .active { wifiPicker }
            }
            .padding(.bottom, last ? 0 : 18)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func marker(_ step: BallSetupFlow.Step, _ status: BallSetupFlow.Status) -> some View {
        ZStack {
            Circle()
                .strokeBorder(status == .pending ? JcTheme.muted.opacity(0.4) : JcTheme.accent, lineWidth: 2)
                .background(Circle().fill(status == .done ? JcTheme.accent.opacity(0.18) : .clear))
            switch status {
            case .pending:
                Text("\(step.rawValue + 1)").font(.caption.weight(.bold)).foregroundStyle(JcTheme.muted)
            case .active:
                ProgressView().controlSize(.small).tint(JcTheme.accent)
            case .done:
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(JcTheme.accent)
            case .failed:
                Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(JcTheme.danger)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var wifiPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if flow.scanning && flow.networks.isEmpty {
                ProgressView("Looking for networks…").tint(JcTheme.accent).foregroundStyle(JcTheme.muted)
            }
            ForEach(flow.networks) { network in
                Button {
                    flow.selectedSSID = network.ssid
                } label: {
                    HStack {
                        Image(systemName: flow.selectedSSID == network.ssid ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(flow.selectedSSID == network.ssid ? JcTheme.accent : JcTheme.muted)
                        Text(network.ssid).foregroundStyle(JcTheme.text).lineLimit(1)
                        Spacer()
                        if network.secure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(JcTheme.muted) }
                        Image(systemName: "wifi", variableValue: signal(network.rssi)).foregroundStyle(JcTheme.muted)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(JcTheme.surface.opacity(flow.selectedSSID == network.ssid ? 1 : 0.5),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if flow.selectedIsSecure && flow.selectedSSID != nil {
                SecureField("Wi-Fi password", text: $flow.password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .padding(12)
                    .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(JcTheme.text)
                    .submitLabel(.go)
                    .onSubmit { if flow.canSubmitWifi { Task { await flow.submitWifi() } } }
            }
            HStack {
                Button("Refresh") { Task { await flow.loadNetworks() } }
                    .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                Spacer()
                Button("Continue") { Task { await flow.submitWifi() } }
                    .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
                    .disabled(!flow.canSubmitWifi)
            }
        }
        .padding(.top, 4)
    }

    private func signal(_ rssi: Int) -> Double {
        min(1, max(0.1, Double(rssi + 90) / 40))
    }
}
