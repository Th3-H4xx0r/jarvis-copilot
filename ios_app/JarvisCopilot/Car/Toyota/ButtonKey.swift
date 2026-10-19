import CryptoKit
import Foundation
import Security

/// The key a Jarvis button signs with when it is set to skip Face ID — disarming the door alarm,
/// silencing it, or a car command from Control Center, a widget or the ring. A second Secure
/// Enclave key with no Face ID on it, usable whenever the phone has been unlocked once since it
/// started. The server takes it only for those commands, and only once the Face ID key has signed
/// its registration (`ToyotaApprover.registerButtonKey`).
protocol ButtonKeySigner: Sendable {
    /// The public half (X9.63, base64), as the server stores it.
    func publicKey() throws -> String
    /// DER-encoded ECDSA P-256 over `message`. No prompt.
    func sign(_ message: Data) throws -> Data
}

/// Whether the server holds this phone's button key, as far as this phone knows. Cleared when the
/// server says it doesn't (`button_key_unknown`), so the next Face ID re-registers it.
enum ButtonKeyRegistration {
    static let key = "jc.buttonKey.registered"

    static var isRegistered: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class SecureEnclaveButtonKey: ButtonKeySigner, @unchecked Sendable {
    static let shared = SecureEnclaveButtonKey()
    private let service = "com.jarviscopilot.button.key"
    private let account = "secure-enclave-key"
    private let lock = NSLock()

    func publicKey() throws -> String {
        try key().publicKey.x963Representation.base64EncodedString()
    }

    /// Never signs with a key made just now: the server only knows a registered one, and a press
    /// signed with a new key would just be refused. The caller falls back to Face ID, which also
    /// registers the new key.
    func sign(_ message: Data) throws -> Data {
        let existed = (try? stored()) != nil
        let key = try key()
        guard existed else { throw CarSignError.unavailable("The button key is new and not registered yet.") }
        return try key.signature(for: message).derRepresentation
    }

    private func stored() throws -> Data? {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    private func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw CarSignError.unavailable("This device has no Secure Enclave.") }
        lock.lock()
        defer { lock.unlock() }
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let blob = item as? Data {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        }
        // A locked Keychain is not "no key": making a new one would orphan the registered one.
        guard status == errSecItemNotFound else {
            throw CarSignError.unavailable("The button key isn't readable right now (\(status)).")
        }
        var problem: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           [.privateKeyUsage], &problem) else {
            throw CarSignError.unavailable("Couldn't make the button key: \(problem?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        var add = query
        add[kSecValueData as String] = made.dataRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw CarSignError.unavailable("Couldn't keep the button key (\(added)).") }
        ButtonKeyRegistration.isRegistered = false
        return made
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
