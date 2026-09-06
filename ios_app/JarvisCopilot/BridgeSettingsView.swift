import SwiftUI

/// What the "are you sure?" prompt says about a scanned pairing QR.
///
/// Pulled out of the view so the wording — which is the entire security value of
/// the step — is testable. Scanning a QR is not consent: the payload names the
/// server that ends up holding a session for this phone, and may carry a
/// Cloudflare Access token to store, so the user has to see the host and agree.
struct BridgePairConfirmation: Equatable {
    let title: String
    let message: String

    init(_ payload: PairingPayload) {
        let server = payload.server ?? ""
        let host: String
        if let parsed = URL(string: server)?.host, !parsed.isEmpty {
            host = parsed
        } else {
            host = server.isEmpty ? "this server" : server
        }
        title = "Pair with \(host)?"

        var lines = ["This phone will be paired with \(host), which can then run commands on it."]
        if payload.code?.isEmpty == false {
            lines.append("The pairing code came from the QR code.")
        }
        if payload.cfClientID?.isEmpty == false || payload.cfClientSecret?.isEmpty == false {
            lines.append("The QR also carries a Cloudflare Access token, which will be stored "
                         + "on this device.")
        }
        message = lines.joined(separator: "\n\n")
    }
}

/// App-level Jarvis Copilot settings: which server, pairing, and whether the bridge runs
/// at all. Individual wearables opt in from their own settings screen.
struct BridgeSettingsView: View {
    @StateObject private var bridge = BridgeClient.shared
    /// Without observing this, the list never refreshes when a device is shared.
    @StateObject private var registry = DeviceRegistry.shared

    @State private var serverURL = BridgeClient.shared.serverURL
    @State private var pairingCode = ""
    @State private var pairingError: String?
    @State private var isPairing = false
    @State private var showScanner = false

    /// Decoded by the scanner sheet, raised as a confirmation once the sheet has
    /// finished dismissing (an alert presented mid-dismissal is unreliable).
    @State private var staged: PairingPayload?
    /// A scanned QR waiting for the user to say yes. Scanning must not be a
    /// decision: the payload names the server that ends up holding a session
    /// cookie for this phone, and it can carry a Cloudflare service token, so
    /// nothing is applied or persisted until this is confirmed.
    @State private var scanned: PairingPayload?
    /// Cloudflare service token from a confirmed scan, held here rather than
    /// written to the Keychain on sight. It must still reach `BridgeClient`
    /// BEFORE the claim (a tunnel 302s a claim with no CF-Access headers to its
    /// SSO login), so `pair()` applies it as the first step of the submit the
    /// user asked for — never on a bare scan.
    @State private var pendingCFClientID: String?
    @State private var pendingCFClientSecret: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                connection
                if bridge.isPaired { behaviour }
                sharedDevices
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        // The port's screen chrome: the aurora behind a clear container and a
        // transparent inline bar, so this pushed screen matches the Settings page
        // it is reached from instead of sitting on flat system black. The scroll
        // container has to give up its own background for the aurora to show.
        .scrollContentBackground(.hidden)
        .jcScreen("Bridge")
        #if os(iOS)
        .sheet(isPresented: $showScanner, onDismiss: {
            if let staged { scanned = staged; self.staged = nil }
        }) {
            // Scanning only stages the payload — see `scanned`.
            PairingScannerSheet { payload in staged = payload }
        }
        .alert(confirmation?.title ?? "Pair?",
               isPresented: Binding(get: { scanned != nil },
                                    set: { if !$0 { scanned = nil } })) {
            Button("Cancel", role: .cancel) { scanned = nil }
            Button("Pair") { confirmScanned() }
        } message: {
            Text(confirmation?.message ?? "")
        }
        #endif
    }

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        CardGroup("Connection",
                  footer: bridge.isPaired
                      ? nil
                      : "Run `jarviscopilot pair` on your server to get a code.") {
            Row {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bridge.status == .online ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(bridge.status.text).foregroundStyle(.secondary)
                    }
                }
            }

            if bridge.isPaired {
                RowDivider()
                Row { LabeledContent("Server", value: bridge.serverURL) }
                RowDivider()
                Row {
                    LabeledContent("Commands shared", value: "\(bridge.registeredSkills)")
                }
                RowDivider()
                Row {
                    Button("Unpair", role: .destructive) { bridge.unpair() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                RowDivider()
                Row {
                    HStack {
                        Text("Server")
                        Spacer(minLength: 12)
                        TextField("jarvis.example.com", text: $serverURL)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onChange(of: serverURL) { _, new in bridge.serverURL = new }
                    }
                }
                #if os(iOS)
                RowDivider()
                Row {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                #endif
                RowDivider()
                Row {
                    HStack {
                        TextField("Pairing code", text: $pairingCode)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                        if isPairing {
                            ProgressView()
                        } else {
                            Button("Pair") { pair() }
                                .disabled(pairingCode.isEmpty || serverURL.isEmpty)
                        }
                    }
                }
                if let pairingError {
                    RowDivider()
                    Row {
                        Text(pairingError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: Scanned-QR confirmation

    private var confirmation: BridgePairConfirmation? {
        scanned.map(BridgePairConfirmation.init)
    }

    /// Apply a payload the user has just confirmed, then claim.
    private func confirmScanned() {
        guard let payload = scanned else { return }
        scanned = nil
        if let server = payload.server, !server.isEmpty {
            serverURL = server
            bridge.serverURL = server
        }
        if let code = payload.code, !code.isEmpty { pairingCode = code }
        pendingCFClientID = payload.cfClientID
        pendingCFClientSecret = payload.cfClientSecret
        // Everything needed and confirmed — claim now; otherwise leave the
        // pre-filled form for the user to finish and submit themselves.
        if !pairingCode.isEmpty, !serverURL.isEmpty { pair() }
    }

    private func pair() {
        // The cookie the claim returns is the whole credential, so it must not
        // travel in the clear. `BridgeClient` assumes https for a bare host.
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.contains("://"), !server.lowercased().hasPrefix("https://") {
            pairingError = "Server URL must be https://"
            return
        }
        isPairing = true
        // Both halves or neither: a lone client id makes the edge reject the
        // claim with a less useful error than sending nothing at all.
        let id = pendingCFClientID ?? ""
        let secret = pendingCFClientSecret ?? ""
        if !id.isEmpty, !secret.isEmpty {
            bridge.applyScanned(cfClientID: id, cfClientSecret: secret)
        }
        Task {
            do {
                pairingError = nil
                try await bridge.pair(code: pairingCode)
                pairingCode = ""
                pendingCFClientID = nil
                pendingCFClientSecret = nil
            } catch {
                pairingError = error.localizedDescription
            }
            isPairing = false
        }
    }

    // MARK: Behaviour

    @ViewBuilder private var behaviour: some View {
        CardGroup("Bridge",
                  footer: "Keeps the app, Bluetooth and the Jarvis link alive in the "
                        + "background so commands arrive instantly. Uses a silent audio "
                        + "session to stay awake, which costs some battery. Nothing is "
                        + "audible and your music is not interrupted.") {
            if let at = bridge.lastPushAt {
                Row {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Last wake",
                                       value: at.formatted(date: .omitted, time: .standard))
                        Text(bridge.lastPushOutcome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                RowDivider()
            }
            Row {
                Toggle("Bridge mode", isOn: Binding(
                    get: { bridge.enabled },
                    set: { on in
                        bridge.enabled = on
                        if on { bridge.connect() } else { bridge.disconnect() }
                    }))
            }
        }
    }

    // MARK: Shared devices

    /// Read-only mirror of what Jarvis can currently see. The opt-in itself lives in
    /// each wearable's own settings.
    @ViewBuilder private var sharedDevices: some View {
        let online = Dictionary(uniqueKeysWithValues:
            registry.devices.map { ($0.deviceID, $0) })
        let records = BridgeClient.sharedRecords.sorted { $0.key < $1.key }

        CardGroup("Shared with Jarvis",
                  footer: records.isEmpty
                      ? "Turn on \"Share with Jarvis\" in a wearable's settings to expose it."
                      : "Offline wearables stay listed — Jarvis sees them again as soon as "
                        + "the app reconnects.") {
            if records.isEmpty {
                Row { Text("Nothing shared").foregroundStyle(.secondary) }
            } else {
                ForEach(Array(records.enumerated()), id: \.element.key) { i, record in
                    if i > 0 { RowDivider() }
                    let device = online[record.key]
                    Row {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.value)
                                Text(device.map { "\($0.capabilities.count) commands" }
                                     ?? record.key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(device != nil ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(device != nil ? "Online" : "Offline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
