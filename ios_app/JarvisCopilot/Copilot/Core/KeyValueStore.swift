import Foundation

/// Preferences boundary so stores are testable without touching `UserDefaults`.
protocol KeyValueStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool?
    func int(_ key: String) -> Int?
    func data(_ key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {
    func string(_ key: String) -> String? { string(forKey: key) }
    func bool(_ key: String) -> Bool? { object(forKey: key) == nil ? nil : bool(forKey: key) }
    func int(_ key: String) -> Int? { object(forKey: key) == nil ? nil : integer(forKey: key) }
    func data(_ key: String) -> Data? { data(forKey: key) }
    func set(_ value: Any?, forKey key: String) {
        if let value { setValue(value, forKey: key) } else { removeObject(forKey: key) }
    }
}

extension UserDefaults: @unchecked Sendable {}

/// In-memory store for tests and previews.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    init(_ initial: [String: Any] = [:]) { values = initial }
    private func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func string(_ key: String) -> String? { get(key) as? String }
    func bool(_ key: String) -> Bool? { get(key) as? Bool }
    func int(_ key: String) -> Int? { get(key) as? Int }
    func data(_ key: String) -> Data? { get(key) as? Data }
    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}
