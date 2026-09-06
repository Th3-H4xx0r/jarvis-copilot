import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// First-run pair screen, ported from `pages/pair_page.dart`.
///
/// The state machine lives in `PairStore`; this file is only the layout.
struct PairPage: View {
    @State private var store: PairStore
    @State private var cameraDenied = false

    /// SwiftUI builds views on the main actor but a view's `init` is not itself
    /// isolated, so the main-actor store can't be a default argument.
    /// `assumeIsolated` is the documented escape: it traps off the main thread,
    /// which a view initialiser never is.
    init(store: PairStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { PairStore() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                scanButton.padding(.top, 28)
                separator.padding(.vertical, 24)
                fields
                cloudflareSection.padding(.top, 4)
                if let message = store.errorMessage {
                    Text(message)
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.danger)
                        .padding(.top, 16)
                }
                BlueButton("Pair", busy: store.phase == .pairing,
                           action: store.canSubmit ? { Task { await store.submit() } } : nil)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .jcScreen("Pair device")
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { store.phase == .scanning },
            set: { if !$0 { store.cancelScanning() } })) {
            scannerSheet
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            JcLogo(size: 80).padding(.bottom, 12)
            Text("Pair with JarvisCopilot")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(JcTheme.text)
            Text("Open the Devices tab on your server\nand tap \"+ Pair new device\".")
                .font(JcText.body)
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var scanButton: some View {
        Button { startScanning() } label: {
            GlassCard(padding: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(JcTheme.primaryBlueHi)
                    Text("Scan QR code")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
            }
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        HStack(spacing: 12) {
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
            Text("or enter manually").font(JcText.small).foregroundStyle(JcTheme.muted)
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
        }
    }

    // MARK: Manual entry

    private var fields: some View {
        VStack(spacing: 12) {
            LabelledField(label: "Server URL") {
                TextField("https://1.2.3.4:8787", text: $store.serverURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .jcFieldStyle()
            }
            LabelledField(label: "Pairing code") {
                TextField("ABC-DEF", text: $store.code)
                    .autocorrectionDisabled()
                    .font(JcText.mono)
                    .kerning(4)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .jcFieldStyle()
            }
            LabelledField(label: "Device name") {
                TextField("My iPhone", text: $store.deviceName)
                    .jcFieldStyle()
            }
        }
    }

    /// Only needed when the server sits behind a Cloudflare tunnel. Opens itself
    /// when a scan carried a token, otherwise the values look like they were
    /// never copied.
    private var cloudflareSection: some View {
        DisclosureGroup(isExpanded: $store.showsCloudflareFields) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste the token from the server's pair popup. Still getting a login "
                   + "redirect (302)? Your Cloudflare Access policy needs Action = Service "
                   + "Auth (NOT \"Allow\" — Allow still requires a browser login): Zero "
                   + "Trust → Access → Applications → your app → Policies → add a Service "
                   + "Auth policy → Include → Service Token.")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted)
                    .lineSpacing(2)
                TextField("xxxxxxxx.access", text: $store.cfClientID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .jcFieldStyle()
                SecureField("CF Access Client Secret", text: $store.cfClientSecret)
                    .jcFieldStyle()
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
        } label: {
            Text("Behind a Cloudflare tunnel? (service token)")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
        }
        .tint(JcTheme.muted)
    }

    // MARK: Scanner

    private func startScanning() {
        #if os(iOS)
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) != .authorized
            guard !cameraDenied else {
                store.errorMessage = "Camera access is off. Allow it in Settings, or type "
                                   + "the pairing code instead."
                return
            }
            store.startScanning()
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var scannerSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let scanner = store.cameraScanner {
                QRPreview(scanner: scanner).ignoresSafeArea()
            }
            VStack {
                Spacer()
                Text(store.scannerMessage
                     ?? store.errorMessage
                     ?? "Point the camera at the pairing QR code")
                    .font(JcText.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                BlueButton("Cancel") { store.cancelScanning() }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
            }
        }
    }
    #endif
}

/// A field with a small caption above it — the pair form's `labelText` decoration
/// as a floating label doesn't exist in SwiftUI.
private struct LabelledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(JcText.small).foregroundStyle(JcTheme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
