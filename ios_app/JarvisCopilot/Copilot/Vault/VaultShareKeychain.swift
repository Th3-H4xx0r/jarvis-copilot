import Foundation
import Security

/// What the "Save to Vault" share extension needs from the app, kept in a Keychain group both
/// targets share: how to reach the server (its URL and the paired session headers), so the
/// extension can upload to the write-only inbox. Nothing about what's IN the vault — not even
/// folder names — is ever shared with it; shares land in the vault's top folder.
///
/// Compiled into the app AND the extension (scripts/add-vault-share-target.rb).
enum VaultShareKeychain {
    /// A team Keychain group both targets list in `keychain-access-groups` (team id + suffix).
    static let accessGroup = "VY5CNF8734.com.jarviscopilot.vaultshare"
    private static let service = "com.jarviscopilot.vault.share"

    struct Server: Codable, Equatable {
        let baseURL: String
        let headers: [String: String]
    }

    static func saveServer(_ server: Server?) {
        guard let server else { remove("server"); return }
        if loadServer() == server { return }
        write("server", try? JSONEncoder().encode(server))
    }

    static func loadServer() -> Server? {
        read("server").flatMap { try? JSONDecoder().decode(Server.self, from: $0) }
    }

    /// Older builds kept the folder tree here for the extension's picker; it's gone.
    static func forgetFolders() {
        remove("folders")
    }

    // MARK: Keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    private static func write(_ account: String, _ data: Data?) {
        guard let data else { return }
        let q = query(account)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            // Readable once the phone has been unlocked after boot, so a share from the lock-screen
            // camera roll still works; never leaves this device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
