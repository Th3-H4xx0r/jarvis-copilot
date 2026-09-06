import Foundation

/// Identifiers and paths shared by the app and the `JarvisWidget` extension.
///
/// This file is compiled into BOTH targets (see `scripts/sync-project.rb`, which
/// registers everything under `Copilot/Shared/` twice) so the App Group id, the
/// URL scheme and the on-disk cache layout can never drift between the process
/// that writes them and the process that reads them.
enum JarvisShared {

    /// MUST match `com.apple.security.application-groups` in BOTH
    /// `JarvisCopilot-iOS.entitlements` and `JarvisWidget/JarvisWidget.entitlements`
    /// — `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
    /// otherwise and every custom Dynamic Island design silently falls back.
    static let appGroupID = "group.com.jarviscopilot.jarviscopilotMobileAndIOS"

    /// The app's custom URL scheme (`CFBundleURLTypes` in Info.plist). The widget
    /// deep-links back through it; `AppDeepLink` parses what arrives.
    static let urlScheme = "jarviscopilot"

    /// The `UserDefaults` flag an App Intent sets so a COLD launch still reaches
    /// the Voice screen — the intent runs in this process before any UI exists,
    /// so a notification alone would be posted to nobody. Same key the Flutter
    /// client used, and the same one `VoiceSettings.pendingVoiceKey` names in the
    /// app target (this copy exists because the widget target has no VoiceSettings).
    static let pendingVoiceKey = "jc_pending_voice"

    /// Posted alongside the flag above, which covers a WARM launch.
    static let startVoiceNotification = "jcStartVoice"

    /// `<AppGroupContainer>/island`, created on demand. Nil when the App Group is
    /// not provisioned (a build without the entitlement, or a unit test).
    static func islandDirectory(container: URL? = defaultContainer(),
                                fileManager: FileManager = .default) -> URL? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("island", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<AppGroupContainer>/island/images`, created on demand.
    static func islandImageDirectory(container: URL? = defaultContainer(),
                                     fileManager: FileManager = .default) -> URL? {
        guard let dir = islandDirectory(container: container, fileManager: fileManager) else { return nil }
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try? fileManager.createDirectory(at: images, withIntermediateDirectories: true)
        return images
    }

    static func defaultContainer(_ fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// `design-<id>.json`, with the id made filesystem-safe. Catalog ids are
    /// slugs, but a crafted one must not be able to escape the island directory.
    static func designFileName(_ id: String) -> String {
        let safe = id
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "design-\(safe).json"
    }
}
