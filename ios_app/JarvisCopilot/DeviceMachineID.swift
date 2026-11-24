import Foundation
import Security

/// This iPhone's stable id for the Jarvis server (2026-11-24): sent when pairing and in every register frame, so the
/// server keeps ONE device record however often the phone re-pairs (a re-pair used to leave a duplicate behind).
/// Random, kept in the Keychain (this device only), so it survives reinstalling the app but not moving to a new phone.
enum DeviceMachineID {
    private static let service = "com.jarviscopilot.machine-id"
    private static let account = "machine-id"
    private static var cached: String?

    static func current() -> String {
        if let cached { return cached }
        let value = read() ?? {
            let fresh = "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            save(fresh)
            return fresh
        }()
        cached = value
        return value
    }

    private static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), s.hasPrefix("ios-") else { return nil }
        return s
    }

    private static func save(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
