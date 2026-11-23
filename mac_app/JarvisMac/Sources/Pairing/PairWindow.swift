import AppKit
import SwiftUI

/// "Pair with your iPhone" in its own window: the QR jc-client made (`pair_qr_start`) on a white
/// card, a countdown (the code renews itself), live state from `pair_state`, and "Type a code
/// instead" (server prefilled from `pair_status`, never a LAN guess). Opens from the menu's
/// Re-pair…, Settings → General → Pair again, and by itself when jc-client says this Mac isn't
/// paired. Replaces jc-client's old Python pairing window.
@MainActor
enum PairWindow {
    private static var window: NSWindow?
    private static var flow: PairFlow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = PairFlow()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Pair with your iPhone"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PairScreen(flow: flow) { [weak w] in w?.close() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        self.flow = flow
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                flow.close()
                window = nil
                self.flow = nil
            }
        }
        flow.open()
    }

    /// jc-client's `pair_state` broadcast, for the open screen.
    static func handle(_ msg: [String: Any]) { flow?.handle(msg) }
}

private struct PairScreen: View {
    let flow: PairFlow
    let close: () -> Void

    @State private var manualOpen = false
    @State private var server = ""
    @State private var code = ""
    @State private var cfOpen = false
    @State private var cfId = ""
    @State private var cfSecret = ""
    @State private var qr: CGImage?

    private let qrSide: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with your iPhone").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            Text("Open Jarvis on your iPhone → Devices → Add computer, then scan this code.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            card.frame(maxWidth: .infinity)
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(flow.stage == .failed ? islandAmber : .white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                if flow.stage == .paired {
                    Button("Done", action: close).buttonStyle(PairButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                } else {
                    if flow.stage == .failed {
                        Button("Show a new code") { flow.newCode() }.buttonStyle(PairButtonStyle(primary: true))
                    }
                    if !manualOpen {
                        Button("Type a code instead") {
                            manualOpen = true
                            fillServer()
                        }
                        .buttonStyle(PairButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if manualOpen && flow.stage != .paired { manualForm }
        }
        .padding(EdgeInsets(top: 34, leading: 24, bottom: 24, trailing: 24))
        .frame(width: 400)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: flow.payload, initial: true) { _, payload in
            qr = payload.flatMap { PairQR.image(for: $0, side: qrSide * 2) }
        }
        .onChange(of: flow.server) { _, _ in fillServer() }
        .task {
            // The countdown, and a fresh code when it runs out.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                flow.tick()
            }
        }
    }

    /// The white card is the code's quiet zone; black on white whatever the accent is.
    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.white)
            if let qr, flow.stage == .waiting || flow.stage == .pairing {
                Image(decorative: qr, scale: 2)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: qrSide, height: qrSide)
                    .opacity(flow.stage == .pairing ? 0.12 : 1)
            }
            switch flow.stage {
            case .loading, .pairing: JcLoader(size: 28).foregroundStyle(.black)
            case .paired: Image(systemName: "checkmark").font(.system(size: 56, weight: .semibold)).foregroundStyle(.black)
            case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 50)).foregroundStyle(.black)
            case .waiting: EmptyView()
            }
        }
        .frame(width: qrSide + 40, height: qrSide + 40)
    }

    private var status: String {
        switch flow.stage {
        case .loading: return "Making a code…"
        case .waiting: return flow.countdown.isEmpty ? "" : "A new code in \(flow.countdown)"
        case .pairing: return "Your iPhone is pairing this Mac…"
        case .paired: return flow.deviceName.isEmpty ? "Paired." : "Paired. This Mac is “\(flow.deviceName)” in Jarvis."
        case .failed: return flow.error ?? "Pairing didn't work."
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On your iPhone: Jarvis → Devices → Add computer → Show a code.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            field("Server", TextField("https://…", text: $server))
            field("Code", TextField("ABC-123", text: $code).onSubmit(pair))
            if cfOpen {
                field("Cloudflare Access client ID", TextField("Client ID", text: $cfId))
                field("Client secret", SecureField("Client secret", text: $cfSecret))
            } else {
                Button("Cloudflare Access token…") { cfOpen = true }.buttonStyle(PairButtonStyle(small: true))
            }
            if let e = flow.manualError {
                Text(e).font(.system(size: 12)).foregroundStyle(islandAmber).fixedSize(horizontal: false, vertical: true)
            }
            Button(flow.manualBusy ? "Pairing…" : "Pair", action: pair)
                .buttonStyle(PairButtonStyle(primary: true))
                .disabled(flow.manualBusy)
        }
        .padding(.top, 4)
    }

    private func field<F: View>(_ label: String, _ input: F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            input
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(JcButton.label)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: JcButton.compactRadius).fill(JcButton.fill))
        }
    }

    private func pair() { flow.manual(server: server, code: code, cfId: cfId, cfSecret: cfSecret) }

    /// The server jc-client knows, once, and never over what he typed.
    private func fillServer() {
        if manualOpen, server.isEmpty, !flow.server.isEmpty { server = flow.server }
    }
}

/// The app's buttons (JcButton): grey with a white label; the one main action white-filled.
private struct PairButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? JcAccent.onFill : JcButton.label)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 5 : 7)
            .background(RoundedRectangle(cornerRadius: JcButton.compactRadius).fill(primary ? JcAccent.fill : JcButton.fill))
            .opacity(!enabled ? JcButton.disabledOpacity : configuration.isPressed ? JcButton.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

/// Settings → General → Pairing: what this Mac is paired with, and Pair again.
struct PairingSettingsSection: View {
    @State private var line = "…"

    var body: some View {
        Section("Pairing") {
            LabeledContent("Jarvis server") {
                HStack(spacing: 10) {
                    Text(line).foregroundStyle(.secondary)
                    Button("Pair again") { PairWindow.show() }
                }
            }
            Text("Shows a code to scan with Jarvis on your iPhone (or type one).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            let probe = PairFlow()
            probe.check { _ in line = PairFlow.summary(paired: probe.isPaired, server: probe.server) }
        }
    }
}
