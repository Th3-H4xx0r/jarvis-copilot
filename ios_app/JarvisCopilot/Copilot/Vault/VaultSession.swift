import SwiftUI
import UIKit

/// The vault's one unlocked session: the server's token, kept in memory only, and everything
/// decrypted for the screens (thumbnails) — dropped together on lock.
///
/// Locks when the server's idle or hard limit passes, when the app goes to the background,
/// when the lock button is tapped, and when the last vault screen leaves. Face ID is offered by
/// itself only when he arrives at the vault (or comes back to it from the background) — never
/// right after a lock he caused or an idle lock, which would just open it again.
@MainActor
final class VaultSession: ObservableObject {
    static let shared = VaultSession()

    @Published private(set) var token: String?
    @Published private(set) var passcodeSet: Bool?
    @Published private(set) var retryAfter: Int?
    @Published var error: String?
    @Published private(set) var working = false
    /// Bumped on every change, so open screens reload (a move from another screen, an upload).
    @Published private(set) var revision = 0

    let api: VaultAPI
    private let approver: ToyotaApprover
    private var idleLimit: TimeInterval = 300
    private var hardDeadline = Date.distantPast
    private var lastActivity = Date()
    private var watchdog: Task<Void, Never>?
    private var visibleScreens = 0
    private var leaveTask: Task<Void, Never>?
    private var lockedInBackground = false
    /// One automatic Face ID offer is owed (he just arrived, or came back from the background).
    private var autoPromptOwed = false
    private let shield = OverlayWindow(level: .alert + 2)

    private let thumbs = NSCache<NSString, UIImage>()

    init(api: VaultAPI = VaultAPI(), approver: ToyotaApprover? = nil) {
        self.api = api
        self.approver = approver ?? ToyotaApprover.shared
        thumbs.countLimit = 400
    }

    var isUnlocked: Bool { token != nil }

    // MARK: Unlock

    func loadStatus() async {
        do {
            let s = try await api.status()
            passcodeSet = s.passcodeSet
            retryAfter = s.retryAfter
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = apiErrorLine(error)
        }
    }

    /// The lock screen asks: should it offer Face ID by itself? Answers yes once per arrival.
    func takeAutoPrompt() -> Bool {
        guard autoPromptOwed, token == nil else { return false }
        autoPromptOwed = false
        return true
    }

    /// Face ID → a signature over `jarvis-vault|unlock|<nonce>|<ts>` → the server's token.
    func unlockWithFaceID() async {
        guard token == nil, !working else { return }
        working = true
        defer { working = false }
        do {
            let proof = try await approver.proof(for: "unlock", title: "Open your vault",
                                                 domain: VaultAPI.signingDomain)
            guard token == nil else { return }
            begin(try await api.unlock(proof: proof))
        } catch CarSignError.cancelled {
            // He backed out of Face ID: stay on the lock screen, passcode still offered.
        } catch let e as CarSignError {
            self.error = Self.faceIDMessage(e)
        } catch VaultError.http(403, let message) {
            approver.forgetRegistration()   // the server's key was replaced: check it again next time
            self.error = message
        } catch {
            self.error = apiErrorLine(error)
        }
    }

    /// The signer's errors speak about the car; say them in the vault's words.
    static func faceIDMessage(_ e: CarSignError) -> String {
        switch e {
        case .cancelled: return "Not approved."
        case .unavailable: return "Face ID isn't available. Use the vault passcode."
        case .otherPhone, .faceIDChanged:
            return "This iPhone's Face ID key doesn't match the server's. Use the vault passcode."
        }
    }

    /// Returns false on a wrong passcode so the pad can shake and clear.
    func unlock(passcode: String) async -> Bool {
        guard token == nil, !working else { return false }
        working = true
        defer { working = false }
        do {
            begin(try await api.unlock(passcode: passcode))
            return true
        } catch {
            self.error = apiErrorLine(error)
            await loadStatus()
            return false
        }
    }

    /// First open: the passcode he chose, vouched for by Face ID, then straight in with it.
    func setUp(passcode: String) async {
        guard !working else { return }
        working = true
        do {
            let proof = try await approver.proof(for: "passcode", title: "Set your vault passcode",
                                                 domain: VaultAPI.signingDomain)
            try await api.setPasscode(passcode, proof: proof)
            passcodeSet = true
            working = false
            _ = await unlock(passcode: passcode)
        } catch CarSignError.cancelled {
            working = false
        } catch let e as CarSignError {
            working = false
            self.error = Self.faceIDMessage(e)
        } catch VaultError.http(403, let message) {
            working = false
            approver.forgetRegistration()
            self.error = message
        } catch {
            working = false
            self.error = apiErrorLine(error)
        }
    }

    private func begin(_ s: VaultAPI.Session) {
        token = s.token
        idleLimit = max(30, s.idle - 10)   // a little inside the server's own limit
        hardDeadline = Date().addingTimeInterval(max(60, s.max - 10))
        lastActivity = Date()
        error = nil
        autoPromptOwed = false
        startWatchdog()
        VaultBlocker.prepare()          // the private browser's blocker, compiled before it's needed
    }

    func lock() {
        guard let token else { return }
        self.token = nil
        thumbs.removeAllObjects()
        watchdog?.cancel()
        watchdog = nil
        VaultTemp.clearShared()
        // Let the server forget the token even if this is the app going to the background.
        let api = api
        let bg = UIApplication.shared.beginBackgroundTask(withName: "vault-lock")
        Task.detached {
            await api.lock(token: token)
            await MainActor.run { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.token != nil else { return }
                let now = Date()
                if now >= self.hardDeadline || now.timeIntervalSince(self.lastActivity) >= self.idleLimit {
                    self.lock()
                    return
                }
            }
        }
    }

    // MARK: Calls

    /// Something is still using the vault (a playing video): keep the session alive.
    func touch() { lastActivity = Date() }

    /// Runs a vault call with the token, keeping the session alive; a 401 for THIS token locks.
    @discardableResult
    func call<T>(_ body: (String) async throws -> T) async throws -> T {
        guard let token else { throw VaultError.locked }
        lastActivity = Date()
        do {
            return try await body(token)
        } catch VaultError.locked {
            // A late reply for a token already replaced must not lock the new session.
            if self.token == token { lock() }
            throw VaultError.locked
        }
    }

    /// Something changed: every open screen reloads.
    func changed() { revision &+= 1 }

    func thumbnail(for item: VaultItem) async -> UIImage? {
        guard item.hasThumb else { return nil }
        let key = "\(item.id)-\(item.updated.timeIntervalSince1970)-\(item.hasThumb)-\(item.thumbAspect ?? 0)" as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        guard let data = try? await call({ try await api.thumb(item.id, token: $0) }),
              let image = UIImage(data: data) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        thumbs.setObject(prepared, forKey: key)
        return prepared
    }

    func favicon(for item: VaultItem) async -> UIImage? {
        guard item.link?.hasFavicon == true else { return nil }
        let key = "fav-\(item.id)" as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        guard let data = try? await call({ try await api.favicon(item.id, token: $0) }),
              let image = UIImage(data: data) else { return nil }
        thumbs.setObject(image, forKey: key)
        return image
    }

    /// The share sheet's folder picker reads these names; it never asks the server.
    /// The paired server, for the share extension's write-only uploads. Called as the app comes forward.
    static func shareServerChanged() {
        VaultShareKeychain.forgetFolders()      // older builds left folder names where the extension could read them
        let api = JarvisAPI.shared
        guard let base = api.credentials.baseURL, api.isPaired else {
            VaultShareKeychain.saveServer(nil)
            return
        }
        VaultShareKeychain.saveServer(.init(baseURL: base.absoluteString, headers: api.credentials.headers))
    }

    // MARK: Screens

    /// A vault screen appeared. Arriving from outside the vault owes one Face ID offer.
    func screenAppeared() {
        if visibleScreens == 0, leaveTask == nil || token == nil { autoPromptOwed = true }
        visibleScreens += 1
        leaveTask?.cancel()
        leaveTask = nil
    }

    /// A vault screen went away. When none is left (after a beat, so a push between two vault
    /// screens doesn't count), the vault locks.
    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
        guard visibleScreens == 0 else { return }
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, self.visibleScreens == 0 else { return }
            self.leaveTask = nil
            self.lock()
            self.shield.hide()
        }
    }

    /// Hides the vault from the app switcher's snapshot, and locks once the app is in the background.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard visibleScreens > 0 else { shield.hide(); return }
        switch phase {
        case .active:
            shield.hide()
            if lockedInBackground {
                lockedInBackground = false
                if token == nil, passcodeSet == true {
                    autoPromptOwed = false
                    Task { await unlockWithFaceID() }
                }
            }
        case .inactive:
            if isUnlocked { shield.show { VaultShieldView() } }
        case .background:
            if isUnlocked {
                shield.show { VaultShieldView() }
                lockedInBackground = true
            }
            lock()
        @unknown default:
            break
        }
    }
}

/// What the app switcher shows while the vault is on screen.
private struct VaultShieldView: View {
    var body: some View {
        ZStack {
            JcTheme.bg.ignoresSafeArea()
            JcIcon("lock.fill", size: 34).foregroundStyle(JcTheme.muted)
        }
    }
}
