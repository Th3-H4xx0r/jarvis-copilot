import Foundation

/// Which Power integrations are switched off, as the app last heard from the server —
/// kept in the App Group so the widget extension, Live Activities, the vault share
/// extension and CarPlay read the same answer as the app.
///
/// Only the OFF ids are stored, so anything unknown (never fetched, a new
/// integration, no App Group) counts as on: a feature is never hidden because a
/// fetch failed.
enum PowerShared {
    static let offKey = "power.off.v1"

    static var defaults: UserDefaults { UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard }

    static func isOn(_ id: String, defaults: UserDefaults = PowerShared.defaults) -> Bool {
        !(defaults.stringArray(forKey: offKey) ?? []).contains(id)
    }

    static func offIDs(defaults: UserDefaults = PowerShared.defaults) -> Set<String> {
        Set(defaults.stringArray(forKey: offKey) ?? [])
    }

    static func store(offIDs: Set<String>, defaults: UserDefaults = PowerShared.defaults) {
        defaults.set(offIDs.sorted(), forKey: offKey)
    }
}
