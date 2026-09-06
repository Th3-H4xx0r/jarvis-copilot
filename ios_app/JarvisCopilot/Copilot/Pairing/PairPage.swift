import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// First-run pair screen.
///
/// The state machine lives in `PairStore`; this file is only the layout. The
/// screen is built as one column: a hero that says what pairing is, the one
/// primary action (scan), then a single frosted card for the manual path with
/// the commit button pinned to the bottom edge so it never scrolls away.
struct PairPage: View {
    @State private var store: PairStore
    @State private var cameraDenied = false
    @State private var haloPhase = false
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            VStack(spacing: 0) {
                hero
                    .padding(.top, 24)
                scanCTA
                    .padding(.top, 26)
                divider
                    .padding(.vertical, 22)
                manualCard
                if let message = store.errorMessage {
                    errorBanner(message)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Color.clear.frame(height: 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.2), value: store.errorMessage)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { pairBar }
        .jcScreen(nil)
        .onAppear { if !reduceMotion { haloPhase = true } }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { store.phase == .scanning },
            set: { if !$0 { store.cancelScanning() } })) {
            scannerSheet
        }
        #endif
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                // A slow breathing halo behind the mark — the screen's one motion.
                Circle()
                    .fill(JcTheme.brandGradient)
                    .frame(width: 132, height: 132)
                    .blur(radius: 34)
                    .opacity(haloPhase ? 0.55 : 0.28)
                    .scaleEffect(haloPhase ? 1.08 : 0.92)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
                               value: haloPhase)
                JcLogo(size: 84)
            }
            .frame(height: 140)

            VStack(spacing: 8) {
                Text("Connect this iPhone")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.center)
                Text("Pair once and Jarvis can reach this phone's skills, voice, and any wearable it drives.")
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }

            steps
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// The three things that happen, so a first-time user knows what the code is.
    private var steps: some View {
        HStack(spacing: 0) {
            step(1, "Server", "Devices → Pair new device")
            stepJoin
            step(2, "Phone", "Scan the QR or type the code")
            stepJoin
            step(3, "Done", "Skills appear on the server")
        }
        .padding(.horizontal, 4)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(JcTheme.text)
                .frame(width: 26, height: 26)
                .background(JcTheme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var stepJoin: some View {
        Rectangle()
            .fill(JcTheme.glassBorder)
            .frame(width: 22, height: 1)
            .offset(y: -22)
    }

    // MARK: Primary action

    private var scanCTA: some View {
        Button { startScanning() } label: {
            HStack(spacing: 12) {
                GlassCircleIcon(symbol: "qrcode.viewfinder", tint: .white, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan QR code")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text("Fastest — fills everything in for you")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(JcTheme.brandGradient)
                    .shadow(color: JcTheme.accent.opacity(0.38), radius: 16, y: 10)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the camera to read the pairing code from the server")
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
            Text("or enter manually")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(JcTheme.muted)
            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
        }
    }

    // MARK: Manual entry

    private var manualCard: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                fieldRow(symbol: "globe", label: "Server URL", valid: urlLooksValid) {
                    TextField("https://jarvis.example.com", text: $store.serverURL)
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
                rowRule
                fieldRow(symbol: "key.horizontal", label: "Pairing code", valid: codeLooksValid) {
                    TextField("ABC-DEF", text: codeBinding)
                        .autocorrectionDisabled()
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .kerning(5)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.asciiCapable)
                        .submitLabel(.next)
                        #endif
                        .focused($focus, equals: .code)
                        .onSubmit { focus = .name }
                }
                rowRule
                fieldRow(symbol: "iphone", label: "Device name", valid: !jcTrim(store.deviceName).isEmpty) {
                    TextField("My iPhone", text: $store.deviceName)
                        #if os(iOS)
                        .submitLabel(.done)
                        #endif
                        .focused($focus, equals: .name)
                        .onSubmit { focus = nil }
                }
                rowRule
                cloudflareSection
            }
        }
    }

    private var rowRule: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 56)
    }

    /// One labelled field in the card: icon, caption, the control, and a check
    /// once the value looks right — validation you can see without submitting.
    private func fieldRow<C: View>(symbol: String, label: String, valid: Bool,
                                   @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            GlassCircleIcon(symbol: symbol, tint: JcTheme.primaryBlueHi, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(JcTheme.muted)
                control()
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.text)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(JcTheme.success)
                .opacity(valid ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: valid)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Uppercases, strips anything that isn't a code character and inserts the
    /// hyphen after the third character, so "abcdef" becomes "ABC-DEF" as typed.
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

    private var urlLooksValid: Bool {
        guard let url = URL(string: jcTrim(store.serverURL)),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty
        else { return false }
        return scheme == "https" || scheme == "http"
    }

    private var codeLooksValid: Bool {
        store.code.filter { $0.isLetter || $0.isNumber }.count == 6
    }

    /// Only needed when the server sits behind a Cloudflare tunnel. Opens itself
    /// when a scan carried a token, otherwise the values look like they were
    /// never copied.
    private var cloudflareSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.showsCloudflareFields.toggle() }
            } label: {
                HStack(spacing: 12) {
                    GlassCircleIcon(symbol: "cloud", tint: JcTheme.amber, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Behind a Cloudflare tunnel?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        Text(store.showsCloudflareFields ? "Service token from the pair popup"
                                                         : "Optional — only for tunnelled servers")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .rotationEffect(.degrees(store.showsCloudflareFields ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.showsCloudflareFields {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("CF Access Client ID (xxxxxxxx.access)", text: $store.cfClientID)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focus, equals: .cfID)
                        .jcFieldStyle()
                    SecureField("CF Access Client Secret", text: $store.cfClientSecret)
                        .focused($focus, equals: .cfSecret)
                        .jcFieldStyle()
                    Text("Still getting a login redirect (302)? The Access policy must be "
                       + "Action = Service Auth, not Allow: Zero Trust → Access → Applications "
                       + "→ your app → Policies → Service Auth → Include → Service Token.")
                        .font(.system(size: 11))
                        .foregroundStyle(JcTheme.muted)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(JcTheme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.text)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(JcTheme.danger.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.35), lineWidth: 1))
    }

    // MARK: Commit bar

    /// The Pair button lives in a bottom inset so it is always reachable, with a
    /// gradient fade so content scrolling underneath doesn't collide with it.
    private var pairBar: some View {
        VStack(spacing: 8) {
            BlueButton(store.phase == .pairing ? "Pairing…" : "Pair",
                       busy: store.phase == .pairing,
                       action: store.canSubmit ? { focus = nil; Task { await store.submit() } } : nil)
            Text(store.canSubmit ? "Your server verifies the code and issues this phone a session."
                                 : "Enter the server URL and the six-character code to continue.")
                .font(.system(size: 11))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            LinearGradient(colors: [JcTheme.bg.opacity(0), JcTheme.bg.opacity(0.92), JcTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
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
            // Framing guide so the user knows where to hold the code.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.5), radius: 12)
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
