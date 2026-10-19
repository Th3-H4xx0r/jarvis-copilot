import Foundation
import WidgetKit

/// Control Center's refresh-push tokens for the Jarvis button and switch controls. With one, the
/// server can make a tile re-read its state within seconds (the exit delay ended, the alarm went
/// off) while the app sleeps. iOS hands them to the widget extension (`JarvisControlPushHandler`),
/// which files them in the App Group; the app sends them on (`ControlPushTokenUploader`).
/// Compiled into the app and the widget.
enum ControlPushTokens {
    static let key = "jc.controlPushTokens"

    static var defaults: UserDefaults { UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard }

    /// The tokens now (hex, sorted, no repeats).
    static func load(defaults: UserDefaults = defaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func save(_ tokens: [Data], defaults: UserDefaults = defaults) {
        save(hex: tokens.map(hex), defaults: defaults)
    }

    static func save(hex tokens: [String], defaults: UserDefaults = defaults) {
        defaults.set(normalized(tokens), forKey: key)
    }

    static func normalized(_ tokens: [String]) -> [String] {
        Array(Set(tokens.filter { !$0.isEmpty })).sorted()
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// iOS's hand-over of the controls' push tokens: replaces the filed set with the current one.
@available(iOS 18.0, *)
struct JarvisControlPushHandler: ControlPushHandler {
    init() {}

    func pushTokensDidChange(controls: [ControlInfo]) {
        ControlPushTokens.save(controls.compactMap { $0.pushInfo?.token })
    }
}
