import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Signs car commands. On the phone: a key in the Secure Enclave that only works after Face ID —
/// the server runs a command (all but stop) only with its fresh signature (plugins/toyota/approver.py).
/// Two steps, so the signed time is taken AFTER Face ID: a slow retry can't go stale on the server.
protocol CarSigner: Sendable {
    /// The public half (X9.63, base64) the server checks signatures against.
    func publicKey() throws -> String
    /// Face ID (`reason` shows if it falls back). Throws `CarSignError.cancelled` when he cancels.
    func authenticate(reason: String) async throws -> CarSignerAuth
    /// Signs with the key Face ID just opened; DER-encoded ECDSA P-256.
    func sign(_ message: Data, auth: CarSignerAuth) async throws -> Data
}

/// What a passed Face ID hands to `sign` (the evaluated context, on the phone).
final class CarSignerAuth: @unchecked Sendable {
    let context: LAContext?
    init(context: LAContext?) { self.context = context }
}

enum CarSignError: LocalizedError, Equatable {
    case cancelled
    case unavailable(String)
    case otherPhone
    case faceIDChanged

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Not approved"
        case .unavailable(let why): return why
        case .otherPhone: return "This iPhone's car key doesn't match the server's (Face ID changed, or a new iPhone). It needs a one-time reset on the server."
        case .faceIDChanged: return "Face ID changed on this iPhone. The car's approval key needs a reset on the server."
        }
    }
}

/// The Secure Enclave signer. The key needs Face ID with the faces enrolled when it was made, and
/// never leaves this iPhone. When Face ID changes (a face added or reset) the key stops working: it is
/// dropped, a new one is made, and the server needs a one-time reset to take the new one.
final class SecureEnclaveCarSigner: CarSigner, @unchecked Sendable {
    static let shared = SecureEnclaveCarSigner()
    private let service = "com.jarviscopilot.car.approver"
    private let account = "secure-enclave-key"
    /// Face ID's enrolment fingerprint when the key was made (not secret).
    private let domainStateKey = "jc.car.approver.faceIDState"
    private let lock = NSLock()

    func publicKey() throws -> String {
        try key(context: nil).publicKey.x963Representation.base64EncodedString()
    }

    func authenticate(reason: String) async throws -> CarSignerAuth {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""   // Face ID only — no "Enter Password"
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                throw CarSignError.cancelled
            case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet:
                throw CarSignError.unavailable("Set up Face ID to use the car's commands.")
            case .biometryLockout:
                throw CarSignError.unavailable("Face ID is locked. Unlock the iPhone with its passcode, then try again.")
            default:
                throw CarSignError.unavailable(error.localizedDescription)
            }
        }
        // Faces added or reset since the key was made: it can't sign any more. Start a new one.
        if let made = UserDefaults.standard.data(forKey: domainStateKey), let now = context.evaluatedPolicyDomainState,
           made != now {
            replaceKey()
            throw CarSignError.faceIDChanged
        }
        return CarSignerAuth(context: context)
    }

    func sign(_ message: Data, auth: CarSignerAuth) async throws -> Data {
        // Off the main thread with the context Face ID just opened: no second prompt.
        try await Task.detached { [self] in
            do {
                return try key(context: auth.context).signature(for: message).derRepresentation
            } catch let error as CarSignError {
                throw error
            } catch {
                // The Secure Enclave refused this key (invalidated): make a new one for next time.
                replaceKey()
                throw CarSignError.faceIDChanged
            }
        }.value
    }

    private func replaceKey() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: domainStateKey)
    }

    private func key(context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw CarSignError.unavailable("This device has no Secure Enclave.") }
        lock.lock()
        defer { lock.unlock() }
        switch read() {
        case .found(let blob):
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        case .failed(let status):
            // Locked Keychain or the like: never treat as "no key" (that would replace the real one).
            throw CarSignError.unavailable("The car key isn't readable right now (\(status)). Try again.")
        case .missing:
            break
        }
        var problem: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &problem) else {
            throw CarSignError.unavailable("Couldn't make the car key: \(problem?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        try write(made.dataRepresentation)
        let probe = context ?? LAContext()
        _ = probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        if let state = probe.evaluatedPolicyDomainState { UserDefaults.standard.set(state, forKey: domainStateKey) }
        return made
    }

    // The key's encrypted handle (useless off this iPhone's Secure Enclave), kept on this device only.
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private enum Stored { case found(Data), missing, failed(OSStatus) }

    private func read() -> Stored {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data else { return .failed(status) }
        return .found(data)
    }

    private func write(_ data: Data) throws {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CarSignError.unavailable("Couldn't keep the car key (\(status)). Try again.")
        }
    }
}

/// Turns a command into the server's signed proof — registering this iPhone's key the first time.
@MainActor
final class ToyotaApprover {
    static let shared = ToyotaApprover()

    struct Proof: Equatable {
        let nonce: String
        let ts: Int
        let signature: String
    }

    let signer: CarSigner
    let api: ToyotaAPI
    private let now: () -> Date
    private var registered: String?

    init(signer: CarSigner = SecureEnclaveCarSigner.shared, api: ToyotaAPI = ToyotaAPI(), now: @escaping () -> Date = Date.init) {
        self.signer = signer
        self.api = api
        self.now = now
    }

    /// Face ID, then a signature over `<domain>|<command>|<nonce>|<ts>` — the time taken after Face ID.
    /// `nonce` is an approval's id when answering Jarvis, else a fresh random one. `domain` keeps the
    /// car's signatures (`jarvis-car`) apart from the door alarm's (`jarvis-home`): the same key signs
    /// both, and the server never accepts one as the other.
    func proof(for command: String, title: String, nonce: String = UUID().uuidString,
               domain: String = "jarvis-car") async throws -> Proof {
        let auth = try await signer.authenticate(reason: title)
        try await ensureRegistered(auth: auth)
        let ts = Int(now().timeIntervalSince1970)
        let signature = try await signer.sign(Data("\(domain)|\(command)|\(nonce)|\(ts)".utf8), auth: auth)
        return Proof(nonce: nonce, ts: ts, signature: signature.base64EncodedString())
    }

    /// After the server refused a signature (reset, key replaced): check the registration again next time.
    func forgetRegistration() { registered = nil }

    /// The first time, this iPhone's key registers itself — signing `jarvis-car-register|<key>|<ts>`
    /// with the Face ID just passed, so nothing that can't sign with it can register a key.
    private func ensureRegistered(auth: CarSignerAuth) async throws {
        let mine = try signer.publicKey()
        if registered == mine { return }
        let theirs = try await api.approverKey()
        if theirs == nil {
            let ts = Int(now().timeIntervalSince1970)
            let signature = try await signer.sign(Data("jarvis-car-register|\(mine)|\(ts)".utf8), auth: auth)
            try await api.registerApprover(publicKey: mine, ts: ts, signature: signature.base64EncodedString())
        } else if theirs != mine {
            throw CarSignError.otherPhone
        }
        registered = mine
    }
}
