import SwiftUI

/// The vault's door: Face ID first, the vault passcode as the fallback, and — the very first
/// time — choosing that passcode.
struct VaultLockView: View {
    @ObservedObject var session: VaultSession
    @State private var mode: Mode = .faceID
    @State private var code = ""
    @State private var firstPick: String?
    @State private var shake = 0

    enum Mode { case faceID, passcode, setup }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            switch mode {
            case .faceID: faceIDPanel
            case .passcode, .setup: pad
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .background(JcTheme.bg.ignoresSafeArea())
        .task {
            await session.loadStatus()
            guard !Task.isCancelled, !session.isUnlocked else { return }
            if session.passcodeSet == false {
                mode = .setup
            } else if session.takeAutoPrompt() {
                await session.unlockWithFaceID()
            }
        }
    }

    // MARK: Face ID

    private var faceIDPanel: some View {
        VStack(spacing: 14) {
            JcIcon("faceid", size: 64)
                .foregroundStyle(JcTheme.text)
                .symbolEffect(.pulse, isActive: session.working)
                .padding(.bottom, 6)
            Text("Secure vault")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(session.working ? "Looking for your face…" : "Locked. Face ID opens it.")
                .font(.system(size: 15))
                .foregroundStyle(JcTheme.muted)
            errorLine
            GradientButton("Open with Face ID", busy: session.working, full: true) {
                Task { await session.unlockWithFaceID() }
            }
            .padding(.top, 18)
            Button("Use vault passcode") {
                session.error = nil
                code = ""
                mode = .passcode
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(JcTheme.muted)
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = session.error {
            Text(error)
                .font(JcText.small)
                .foregroundStyle(JcTheme.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Passcode pad

    private var padTitle: String {
        switch mode {
        case .setup: return firstPick == nil ? "Choose a vault passcode" : "Enter it again"
        default: return "Enter vault passcode"
        }
    }

    private var padSubtitle: String {
        switch mode {
        case .setup: return "6 digits, separate from your iPhone passcode. You'll need it if Face ID can't be used."
        default:
            if let wait = session.retryAfter, wait > 0 { return "Too many tries. Try again in \(wait) s." }
            return "Needed after a restart, or when Face ID doesn't work"
        }
    }

    private var pad: some View {
        VStack(spacing: 10) {
            JcIcon("lock.fill", size: 26).foregroundStyle(JcTheme.text)
            Text(padTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .padding(.top, 6)
            Text(padSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .strokeBorder(JcTheme.text, lineWidth: 1.5)
                        .background(Circle().fill(i < code.count ? JcTheme.text : .clear))
                        .frame(width: 13, height: 13)
                }
            }
            .modifier(Shake(amount: CGFloat(shake)))
            .animation(.default, value: shake)
            .padding(.vertical, 18)
            errorLine
            keypad
            if mode == .passcode {
                Button("Use Face ID") {
                    session.error = nil
                    mode = .faceID
                    Task { await session.unlockWithFaceID() }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.muted)
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 22), count: 3), spacing: 14) {
            ForEach(keys.indices, id: \.self) { i in
                let key = keys[i]
                if key.isEmpty {
                    Color.clear.frame(width: 76, height: 76)
                } else {
                    Button { press(key) } label: {
                        Group {
                            if key == "⌫" {
                                JcIcon("delete.left", size: 22)
                            } else {
                                Text(key).font(.system(size: 30, weight: .regular))
                            }
                        }
                        .foregroundStyle(JcTheme.text)
                        .frame(width: 76, height: 76)
                        .background(key == "⌫" ? Color.clear : JcButton.fill, in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.working)
                    .accessibilityLabel(key == "⌫" ? "Delete" : key)
                }
            }
        }
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !code.isEmpty { code.removeLast() }
            return
        }
        guard code.count < 6 else { return }
        code.append(key)
        guard code.count == 6 else { return }
        let entered = code
        Task { await submit(entered) }
    }

    private func submit(_ entered: String) async {
        switch mode {
        case .setup:
            if let first = firstPick {
                if first == entered {
                    await session.setUp(passcode: entered)
                    if !session.isUnlocked { firstPick = nil }
                } else {
                    session.error = "Those didn't match. Choose again."
                    firstPick = nil
                    wrong()
                }
            } else {
                firstPick = entered
                session.error = nil
            }
            code = ""
        default:
            let ok = await session.unlock(passcode: entered)
            if !ok { wrong() }
            code = ""
        }
    }

    private func wrong() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        shake += 1
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}

// MARK: - Screen guard

extension View {
    /// Every vault screen: counts itself for the auto-lock, hides from the app switcher, and covers
    /// itself with the lock screen whenever the vault is locked. The screen stays alive underneath
    /// (so its sheets, navigation and unsaved typing survive a lock) but hidden and inert.
    func vaultScreen(_ session: VaultSession) -> some View {
        modifier(VaultScreenModifier(session: session))
    }

    /// The vault's page header: the app's large title and action pill, without handing the title
    /// to the battery ledger (which writes screen names to disk) — vault names stay in the vault.
    func vaultChrome<Actions: View>(_ title: String, header: JcScreenHeader = .large,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        modifier(VaultChrome(title: title, header: header, actions: actions()))
    }
}

private struct VaultChrome<Actions: View>: ViewModifier {
    let title: String
    let header: JcScreenHeader
    let actions: Actions

    func body(content: Content) -> some View {
        content
            .background(JcTheme.bg.ignoresSafeArea())
            .onAppear { EnergyLedger.shared.screenAppeared("Vault") }
            .onDisappear { EnergyLedger.shared.screenDisappeared("Vault") }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(header == .inline ? .inline : .large)
            .toolbar {
                if Actions.self != EmptyView.self {
                    ToolbarItemGroup(placement: .topBarTrailing) { actions }
                }
            }
    }
}

private struct VaultScreenModifier: ViewModifier {
    @ObservedObject var session: VaultSession
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(session.isUnlocked ? 1 : 0)
                .allowsHitTesting(session.isUnlocked)
                .accessibilityHidden(!session.isUnlocked)
            if !session.isUnlocked {
                VaultLockView(session: session)
            }
        }
        .onAppear { session.screenAppeared() }
        .onDisappear { session.screenDisappeared() }
        .onChange(of: scenePhase) { _, phase in session.scenePhaseChanged(phase) }
    }
}
