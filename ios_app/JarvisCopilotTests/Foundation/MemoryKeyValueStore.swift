import Foundation
@testable import JarvisCopilot

/// In-memory store for tests and previews.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    init(_ initial: [String: Any] = [:]) { values = initial }
    private func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func string(_ key: String) -> String? { get(key) as? String }
    func bool(_ key: String) -> Bool? { get(key) as? Bool }
    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}
