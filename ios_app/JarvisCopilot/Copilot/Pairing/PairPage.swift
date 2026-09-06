import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// First-run pair screen. The state machine lives in `PairStore`; this file is
/// only the layout: mark, one line, scan, an inset form, Pair.
struct PairPage: View {
    @State private var store: PairStore
    @FocusState private var focus: Field?
    @State private var step: Step = .welcome
    @State private var showManual = false
    /// Drives the staggered entrance of each screen's elements; reset on step change.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step { case welcome, connect }

    private enum Field: Hashable { case url, code, name, cfID, cfSecret }

    /// SwiftUI builds views on the main actor but a view's `init` is not itself
    /// isolated, so the main-actor store can't be a default argument.
    /// `assumeIsolated` is the documented escape: it traps off the main thread,
    /// which a view initialiser never is.
    init(store: PairStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { PairStore() })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if step == .welcome {
                    welcome
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    connect
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            // Tap anywhere that isn't a control to put the keyboard away.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { focus = nil })
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
            .animation(.easeInOut(duration: 0.22), value: showManual)
        }
        // Fixed page while everything fits; it only scrolls once the keyboard
        // takes the bottom of the screen.
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .jcScreen(step == .welcome ? nil : "Connect")
        .toolbar {
            if step == .connect {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { withAnimation { step = .welcome; focus = nil } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    }
                    .tint(JcTheme.text)
                }
            }
        }
        // A scanned QR that carried a Cloudflare token opens the manual form so
        // the values it filled are visible.
        .onChange(of: store.showsCloudflareFields) { _, shown in if shown { showManual = true } }
        .onAppear { revealed = true }
        .onChange(of: step) { _, _ in
            revealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { revealed = true }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { store.phase == .scanning },
            set: { if !$0 { store.cancelScanning() } })) {
            scannerSheet
        }
        #endif
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VoiceOrb(state: .idle, amplitude: 0.16, size: 260)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .modifier(Entrance(revealed: revealed, index: 0, scale: true, reduceMotion: reduceMotion))
            VStack(spacing: 10) {
                Text("Hey, I'm Jarvis.")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                    .modifier(Entrance(revealed: revealed, index: 1, reduceMotion: reduceMotion))
                Text("Your assistant across every device you own.")
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .modifier(Entrance(revealed: revealed, index: 2, reduceMotion: reduceMotion))
            }
            .padding(.top, 8)
            Spacer(minLength: 40)
            Button { withAnimation { step = .connect } } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 64, height: 64)
                    .background(JcTheme.blueGradient, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: JcTheme.primaryBlue.opacity(0.45), radius: 14, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next")
            .modifier(Entrance(revealed: revealed, index: 3, reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, minHeight: 620)
    }

    // MARK: Connect

    private var connect: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                VoiceOrb(state: .idle, amplitude: 0.12, size: 150)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .modifier(Entrance(revealed: revealed, index: 0, scale: true, reduceMotion: reduceMotion))
                Text("Connect to your server")
                    .font(JcText.title)
                    .foregroundStyle(JcTheme.text)
                    .modifier(Entrance(revealed: revealed, index: 1, reduceMotion: reduceMotion))
                Text("On the server, open Devices and tap Pair new device.")
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .modifier(Entrance(revealed: revealed, index: 2, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity)

            if !showManual {
                BlueButton("Scan QR code") { startScanning() }
                    .modifier(Entrance(revealed: revealed, index: 3, reduceMotion: reduceMotion))
                Button { withAnimation { showManual = true } } label: {
                    Text("Enter details manually")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .underline()
                }
                .buttonStyle(.plain)
                .modifier(Entrance(revealed: revealed, index: 4, reduceMotion: reduceMotion))
            } else {
                form
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                cloudflare
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                if let message = store.errorMessage {
                    Text(message)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                BlueButton("Pair", busy: store.phase == .pairing,
                           action: store.canSubmit ? { focus = nil; Task { await store.submit() } } : nil)
                Button { startScanning() } label: {
                    Label("Scan QR code instead", systemImage: "qrcode.viewfinder")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                }
                .buttonStyle(.plain)
            }
            if let message = store.errorMessage, !showManual {
                Text(message)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.danger)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Form

    private var form: some View {
        GlassGroup {
            formRow("Server") {
                TextField("https://…", text: $store.serverURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.next)
                    #endif
                    .focused($focus, equals: .url)
                    .onSubmit { focus = .code }
            }
            rule
            formRow("Code") {
                TextField("ABC-DEF", text: codeBinding)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.next)
                    #endif
                    .focused($focus, equals: .code)
                    .onSubmit { focus = .name }
            }
            rule
            formRow("Name") {
                TextField("iPhone", text: $store.deviceName)
                    #if os(iOS)
                    .submitLabel(.done)
                    #endif
                    .focused($focus, equals: .name)
                    .onSubmit { focus = nil }
            }
        }
    }

    /// Settings-style row: label on the left, value on the right.
    private func formRow<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(JcText.body)
                .foregroundStyle(JcTheme.text)
                .frame(width: 64, alignment: .leading)
            control()
                .font(JcText.body)
                .foregroundStyle(JcTheme.text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var rule: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 16)
    }

    /// Uppercases, keeps code characters and inserts the hyphen after the third,
    /// so "abcdef" becomes "ABC-DEF" as typed.
    private var codeBinding: Binding<String> {
        Binding(
            get: { store.code },
            set: { raw in
                let chars = raw.uppercased().filter { $0.isLetter || $0.isNumber }
                let head = String(chars.prefix(3))
                let tail = String(chars.dropFirst(3).prefix(3))
                store.code = tail.isEmpty ? (chars.count > 3 ? head + "-" : head) : head + "-" + tail
            })
    }

    // MARK: Cloudflare

    /// Only needed when the server sits behind a Cloudflare tunnel. Opens itself
    /// when a scan carried a token.
    private var cloudflare: some View {
        GlassGroup {
            GlassRow(symbol: "cloud", title: "Cloudflare Access token",
                     subtitle: store.showsCloudflareFields ? nil : "Only if the server is tunnelled",
                     last: !store.showsCloudflareFields) {
                withAnimation(.easeInOut(duration: 0.2)) { store.showsCloudflareFields.toggle() }
            }
            if store.showsCloudflareFields {
                rule
                formRow("Client ID") {
                    TextField("xxxxxxxx.access", text: $store.cfClientID)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focus, equals: .cfID)
                }
                rule
                formRow("Secret") {
                    SecureField("Client secret", text: $store.cfClientSecret)
                        .focused($focus, equals: .cfSecret)
                }
                Text("If the server still redirects to a login page, the Access policy must use "
                   + "Service Auth, not Allow.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
    }

    // MARK: Scanner

    private func startScanning() {
        #if os(iOS)
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                store.errorMessage = "Camera access is off. Allow it in Settings, or type the code."
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

/// Staggered entrance: each element rises 18 pt and fades in, `index` × 90 ms
/// after the screen appears; the orb also scales from 0.9. Off under Reduce Motion.
private struct Entrance: ViewModifier {
    let revealed: Bool
    let index: Int
    var scale: Bool = false
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shown = revealed || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .scaleEffect(scale && !shown ? 0.9 : 1)
            .animation(reduceMotion ? nil
                       : .spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.09),
                       value: shown)
    }
}
