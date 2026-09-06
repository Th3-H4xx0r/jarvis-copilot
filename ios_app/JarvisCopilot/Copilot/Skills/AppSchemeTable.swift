import Foundation

/// Friendly app name → URL scheme.
///
/// iOS doesn't expose a public API to launch an app by display name, only by its
/// registered URL scheme, so `open_app` resolves through this table.
///
/// IMPORTANT: a scheme here also has to appear in `LSApplicationQueriesSchemes`
/// in Info.plist, otherwise `canOpenURL` returns false even when the app is
/// installed. We open regardless and report the real outcome, so an undeclared
/// scheme degrades to "launched: false" rather than a lie.
///
/// Ported from `mobile_client/ios/Runner/AppOpenBridge.swift`.
enum AppSchemeTable {
    static let knownApps: [String: String] = [
        "twitter": "twitter://",
        "x": "twitter://",
        "instagram": "instagram://",
        "facebook": "fb://",
        "messenger": "fb-messenger://",
        "whatsapp": "whatsapp://",
        "telegram": "tg://",
        "signal": "sgnl://",
        "slack": "slack://",
        "spotify": "spotify://",
        "youtube": "youtube://",
        "tiktok": "snssdk1233://",
        "maps": "maps://",
        "google maps": "comgooglemaps://",
        "googlemaps": "comgooglemaps://",
        "gmail": "googlegmail://",
        "chrome": "googlechrome://",
        "safari": "x-web-search://",
        "calendar": "calshow://",
        "notes": "mobilenotes://",
        "reminders": "x-apple-reminderkit://",
        "shortcuts": "shortcuts://",
        "settings": "App-Prefs:",
        "uber": "uber://",
        "lyft": "lyft://",
        "github": "github://",
        "discord": "discord://",
        "zoom": "zoomus://",
    ]

    /// The URL string to try for this request, or nil when there's nothing to
    /// attempt. Order: an explicit scheme wins, then the table, then the app's
    /// condensed name as a scheme ("wells fargo" → "wellsfargo://") — many apps
    /// register exactly that.
    static func resolve(appName: String, schemeURL: String) -> String? {
        let explicit = schemeURL.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        let name = appName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty { return nil }
        if let mapped = knownApps[name] ?? knownApps[name.replacingOccurrences(of: " ", with: "")] {
            return mapped
        }
        let condensed = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
        return condensed.isEmpty ? nil : "\(condensed)://"
    }
}
