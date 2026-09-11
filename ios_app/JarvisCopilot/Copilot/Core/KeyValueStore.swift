import Foundation

/// Preferences boundary so stores are testable without touching `UserDefaults`.
protocol KeyValueStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {
    func string(_ key: String) -> String? { string(forKey: key) }
    func bool(_ key: String) -> Bool? { object(forKey: key) == nil ? nil : bool(forKey: key) }
    func set(_ value: Any?, forKey key: String) {
        if let value { setValue(value, forKey: key) } else { removeObject(forKey: key) }
    }
}

extension UserDefaults: @unchecked Sendable {}
