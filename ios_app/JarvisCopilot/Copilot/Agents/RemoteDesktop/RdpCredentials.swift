import CryptoKit
import Foundation
import LocalAuthentication
import Security

// The Remote Desktop password reaches the phone encrypted to a Secure-Enclave key, so the server
// only ever relays ciphertext (Task 6 of docs/superpowers/plans/2026-11-15-remote-desktop.md):
//   ECDH P-256 → HKDF-SHA256 (salt empty, info "jarvis-rdp-v1", 32 bytes) → AES-256-GCM
//   (12-byte nonce, 16-byte tag appended to the ciphertext).
// The PC encrypts to the `enc_pub` inside the context his Face ID signed; the phone opens it with
// the evaluated Face ID context from that same approval, hands it to FreeRDP in memory and wipes it.

enum RdpCredentialError: Error, Equatable {
    case badCredential
    case noKey
}

enum RdpEcies {
    static let info = Data("jarvis-rdp-v1".utf8)

    /// Opens `ciphertextWithTag` (AES-GCM ciphertext ‖ 16-byte tag) to UTF-8 text.
    static func open(ciphertextWithTag: Data, ephemeralPublicX963: Data, nonce: Data,
                     agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> String {
        guard ciphertextWithTag.count > 16, nonce.count == 12 else { throw RdpCredentialError.badCredential }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicX963)
        let key = try agree(ephemeral).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info,
                                                               outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: ciphertextWithTag.dropLast(16),
                                        tag: ciphertextWithTag.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw RdpCredentialError.badCredential }
        return text
    }

    /// The PC's `credential` frame: {"ciphertext","ephemeral_pub","nonce"}, all base64.
    static func parts(_ credential: [String: Any]) throws -> (ciphertext: Data, ephemeral: Data, nonce: Data) {
        func b64(_ k: String) throws -> Data {
            guard let s = credential[k] as? String, let d = Data(base64Encoded: s) else { throw RdpCredentialError.badCredential }
            return d
        }
        return (try b64("ciphertext"), try b64("ephemeral_pub"), try b64("nonce"))
    }
}

/// The phone's key for Remote Desktop: in the Secure Enclave, usable only after Face ID
/// (biometry, current set). The simulator has no enclave: a software key in the Keychain there.
final class RdpKey: @unchecked Sendable {
    static let shared = RdpKey()

    private let account = "rdp.ecies.v1"
    private let service = "com.jarviscopilot.rdp"
    private let lock = NSLock()

    /// The real enclave on a phone; the simulator's can't do biometric access control.
    private var useEnclave: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclave.isAvailable
        #endif
    }

    /// The public half (X9.63, 65 bytes) the server puts in the signed context as `enc_pub`.
    func publicX963() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if useEnclave {
            if let blob = load(), let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob) {
                return key.publicKey.x963Representation
            }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                               [.privateKeyUsage, .biometryCurrentSet], &error) else {
                throw RdpCredentialError.noKey
            }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            save(key.dataRepresentation)
            return key.publicKey.x963Representation
        }
        if let raw = load(), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key.publicKey.x963Representation
        }
        let key = P256.KeyAgreement.PrivateKey()
        save(key.rawRepresentation)
        return key.publicKey.x963Representation
    }

    /// ECDH with the PC's one-off key. `context` is the Face ID the approval just passed (nil
    /// asks for Face ID again).
    func agree(_ ephemeral: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        lock.lock(); defer { lock.unlock() }
        guard let blob = load() else { throw RdpCredentialError.noKey }
        if useEnclave {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            return try key.sharedSecretFromKeyAgreement(with: ephemeral)
        }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: blob).sharedSecretFromKeyAgreement(with: ephemeral)
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// This launch's copy (an unsigned build — tests — has no Keychain).
    private var cached: Data?

    private func load() -> Data? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data { return data }
        return cached
    }

    private func save(_ data: Data) {
        cached = data
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

enum RdpCredentials {
    /// Opens the PC's credential with the phone's key (Task 8 interface).
    static func open(ciphertext: Data, ephemeralPub: Data, nonce: Data, context: LAContext? = nil,
                     key: RdpKey = .shared) throws -> String {
        try RdpEcies.open(ciphertextWithTag: ciphertext, ephemeralPublicX963: ephemeralPub, nonce: nonce) {
            try key.agree($0, context: context)
        }
    }
}

/// The opened password, in memory only, for one session (and a reconnect within 60 s).
/// Zeroed when the session ends.
final class RdpSecret {
    private var bytes: [UInt8]
    let openedAt: Date

    init(_ text: String, openedAt: Date = Date()) {
        bytes = Array(text.utf8)
        self.openedAt = openedAt
    }

    var isWiped: Bool { bytes.isEmpty }

    /// Runs `body` with a NUL-terminated C string of the password.
    func withCString<T>(_ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        var buffer = bytes.map { CChar(bitPattern: $0) } + [0]
        defer { for i in buffer.indices { buffer[i] = 0 } }
        return try buffer.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    func wipe() {
        for i in bytes.indices { bytes[i] = 0 }
        bytes.removeAll()
    }

    deinit { wipe() }
}
