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
    /// The orb is ONE view drawn over both screens; this is the step whose slot
    /// it is currently sitting in (it moves ahead of the content swap).
    @State private var orbStep: Step = .welcome
    /// False while the outgoing screen fades away before the orb travels.
    @State private var contentVisible = true

    private static let orbWelcomeSize: CGFloat = 260
    private static let orbConnectSize: CGFloat = 150
    private static let columnTop: CGFloat = 20
    /// Where each screen's orb slot currently sits (top edge, in the page's
    /// coordinate space). Published by the slots so the overlay orb can travel to
    /// the exact spot even when the connect column is vertically centred.
    @State private var slotTop: [Step: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum StepKey: Hashable { case welcome, connect }
    private typealias Step = StepKey

    private enum Field: Hashable { case url, code, name, cfID, cfSecret }

    /// SwiftUI builds views on the main actor but a view's `init` is not itself
    /// isolated, so the main-actor store can't be a default argument.
    /// `assumeIsolated` is the documented escape: it traps off the main thread,
    /// which a view initialiser never is.
    init(store: PairStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { PairStore() })
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 24) {
                        if step == .welcome { welcome(height: geo.size.height) }
                        else { connect(height: geo.size.height) }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .opacity(contentVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.22), value: contentVisible)
                    // Tap anywhere that isn't a control to put the keyboard away.
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { focus = nil })
                    .animation(.easeInOut(duration: 0.22), value: showManual)
                }
                // Fixed page while everything fits; it only scrolls once the keyboard
                // takes the bottom of the screen.
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(SlotTopKey.self) { slotTop = $0 }

                // The shared orb: one view over both screens, scaled from its top
                // edge and moved to whichever slot `orbStep` names.
                VoiceOrb(state: .idle, amplitude: 0.14, size: Self.orbWelcomeSize)
                    .scaleEffect(orbStep == .welcome ? 1 : Self.orbConnectSize / Self.orbWelcomeSize,
                                 anchor: .top)
                    .offset(y: slotTop[orbStep] ?? Self.columnTop)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85),
                               value: orbStep)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85),
                               value: slotTop)

                if step == .connect {
                    HStack {
                        GlassIconButton(symbol: "chevron.left", size: 36, iconSize: 15) {
                            go(to: .welcome)
                        }
                        .modifier(Entrance(revealed: revealed, index: 0, reduceMotion: reduceMotion))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
            .coordinateSpace(name: "pair")
        }
        .background(LivingAurora(reduceMotion: reduceMotion).ignoresSafeArea())
        // A scanned QR that carried a Cloudflare token opens the manual form so
        // the values it filled are visible.
        .onChange(of: store.showsCloudflareFields) { _, shown in if shown { showManual = true } }
        .onAppear { revealed = true }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { store.phase == .scanning },
            set: { if !$0 { store.cancelScanning() } })) {
            scannerSheet
        }
        #endif
    }

    // MARK: Step transition

    /// Fade the current content out, move the orb, then fade the next content in.
    private func go(to target: Step) {
        guard target != step else { return }
        focus = nil
        if reduceMotion {
            step = target; orbStep = target; revealed = true
            return
        }
        contentVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            // Lay the next screen out while still invisible so its orb slot
            // reports a position, then send the orb there.
            revealed = false
            step = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { orbStep = target }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            contentVisible = true
            revealed = true
        }
    }

    // MARK: Welcome

    private func welcome(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // Orb + headline sit at the exact vertical centre (equal spacers).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                orbSlot(.welcome, size: Self.orbWelcomeSize)
                VStack(spacing: 10) {
                    WordReveal("Hey, I'm Jarvis.", font: .system(size: 34, weight: .bold),
                               color: JcTheme.text, revealed: revealed, startDelay: 0.25,
                               step: 0.16, reduceMotion: reduceMotion)
                    WordReveal("Your assistant across every device you own.", font: JcText.body,
                               color: JcTheme.muted, revealed: revealed, startDelay: 0.85,
                               step: 0.07, reduceMotion: reduceMotion)
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
            // The arrow is pinned to the bottom, outside the centred group.
            Button { go(to: .connect) } label: {
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
            .padding(.bottom, 8)
        }
        .padding(.top, Self.columnTop)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, minHeight: height)
    }

    /// An invisible box the size of the orb; publishes its top edge so the
    /// overlay orb can sit exactly here.
    private func orbSlot(_ which: Step, size: CGFloat) -> some View {
        Color.clear
            .frame(height: size)
            .background(GeometryReader { g in
                Color.clear.preference(key: SlotTopKey.self,
                                       value: [which: g.frame(in: .named("pair")).minY])
            })
    }

    // MARK: Connect

    private func connect(height: CGFloat) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                orbSlot(.connect, size: Self.orbConnectSize)
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
            Spacer(minLength: 0)
        }
        .padding(.top, Self.columnTop)
        .padding(.bottom, 24)
        // Centred while it fits; grows past the height once the manual form is out.
        .frame(maxWidth: .infinity, minHeight: showManual ? nil : height)
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

private struct SlotTopKey: PreferenceKey {
    static var defaultValue: [PairPage.StepKey: CGFloat] = [:]
    static func reduce(value: inout [PairPage.StepKey: CGFloat], nextValue: () -> [PairPage.StepKey: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The aurora, alive: four soft colour fields drifting on slow Lissajous paths.
/// Same palette and weight as `AuroraBackdrop`, so the page still reads as the
/// rest of the app — it just breathes. Static under Reduce Motion.
private struct LivingAurora: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    LinearGradient(colors: [Color(jcHex: 0x04050A), Color(jcHex: 0x020307)],
                                   startPoint: .top, endPoint: .bottom)
                    // Small, deep-toned glows on slow orbits — an accent in the dark,
                    // never a light show.
                    blob(Color(jcHex: 0x123A8C), 0.16, 160,
                         x: w * (0.28 + 0.36 * sin(t / 4.2)), y: h * (0.20 + 0.20 * cos(t / 3.6)))
                    blob(Color(jcHex: 0x0C4C55), 0.14, 150,
                         x: w * (0.72 + 0.34 * cos(t / 3.9 + 1)), y: h * (0.52 + 0.28 * sin(t / 4.6)))
                    blob(Color(jcHex: 0x2C1E6E), 0.14, 170,
                         x: w * (0.42 + 0.40 * sin(t / 5.1 + 2)), y: h * (0.80 + 0.16 * cos(t / 4.0 + 1)))
                    blob(Color(jcHex: 0x3A1F4E), 0.10, 130,
                         x: w * (0.60 + 0.36 * cos(t / 4.4 + 3)), y: h * (0.36 + 0.32 * sin(t / 5.3 + 2)))
                }
            }
        }
    }

    private func blob(_ color: Color, _ alpha: Double, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(alpha))
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
            .position(x: x, y: y)
    }
}

/// A line of text whose words fade and rise in one after another.
private struct WordReveal: View {
    let words: [String]
    let font: Font
    let color: Color
    let revealed: Bool
    let startDelay: Double
    let step: Double
    let reduceMotion: Bool

    init(_ text: String, font: Font, color: Color, revealed: Bool,
         startDelay: Double, step: Double, reduceMotion: Bool) {
        words = text.split(separator: " ").map(String.init)
        self.font = font; self.color = color; self.revealed = revealed
        self.startDelay = startDelay; self.step = step; self.reduceMotion = reduceMotion
    }

    var body: some View {
        let shown = revealed || reduceMotion
        HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                Text(word + (i < words.count - 1 ? " " : ""))
                    .font(font)
                    .foregroundStyle(color)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 10)
                    .blur(radius: shown ? 0 : 3)
                    .animation(reduceMotion ? nil
                               : .easeOut(duration: 0.5).delay(startDelay + Double(i) * step),
                               value: shown)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity)
    }
}
