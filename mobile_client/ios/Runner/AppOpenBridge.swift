import Flutter
import UIKit

/// MethodChannel for the `open_app` skill on iOS.
///
/// iOS doesn't expose a public API to launch an app by display name —
/// only by its registered URL scheme. We accept both `scheme_url` and
/// a friendly `app` argument, mapping known names to schemes via the
/// table below. Apps not in the table will be findable only if the
/// caller knows the scheme.
///
/// IMPORTANT: every scheme used here also needs to appear in
/// `LSApplicationQueriesSchemes` in Info.plist, otherwise
/// `UIApplication.canOpenURL` returns false even when the app is
/// installed.
class AppOpenBridge {
    /// Common-app friendly-name → URL-scheme table. Add to this as
    /// you find more useful schemes; keep Info.plist's
    /// LSApplicationQueriesSchemes in sync.
    private static let knownApps: [String: String] = [
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

    static func register(with controller: FlutterViewController) {
        let ch = FlutterMethodChannel(
            name: "jarviscopilot/app",
            binaryMessenger: controller.binaryMessenger
        )
        ch.setMethodCallHandler { (call, result) in
            switch call.method {
            case "open":
                guard let args = call.arguments as? [String: Any] else {
                    result(FlutterError(code: "bad_args", message: "no args", details: nil))
                    return
                }
                let app = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let scheme = (args["scheme_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                open(appName: app, schemeUrl: scheme, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func open(appName: String, schemeUrl: String, result: @escaping FlutterResult) {
        // 1. Explicit scheme URL wins.
        if !schemeUrl.isEmpty, let url = URL(string: schemeUrl) {
            launch(url: url, matched: schemeUrl, result: result)
            return
        }
        // 2. Friendly name → mapped scheme.
        if !appName.isEmpty, let mapped = knownApps[appName] ?? knownApps[appName.replacingOccurrences(of: " ", with: "")] {
            if let url = URL(string: mapped) {
                launch(url: url, matched: appName, result: result)
                return
            }
        }
        // 3. Last-ditch — try the app's condensed name as a scheme
        // ("wells fargo" → "wellsfargo://"). Many apps register their squashed
        // name; UIApplication.open still attempts it whether or not the scheme
        // is in LSApplicationQueriesSchemes, and reports back whether it
        // actually launched (so the caller never claims a false success).
        let condensed = appName.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        if !condensed.isEmpty, let url = URL(string: "\(condensed)://") {
            launch(url: url, matched: appName, result: result)
            return
        }
        result(["launched": false, "error": "no scheme for \"\(appName)\""])
    }

    private static func launch(url: URL, matched: String, result: @escaping FlutterResult) {
        // canOpenURL only returns true for schemes declared in
        // LSApplicationQueriesSchemes. If the app is installed but
        // the scheme isn't declared, this returns false — we still
        // attempt to open it so the caller gets a meaningful result.
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                result([
                    "launched": ok,
                    "scheme_url": url.absoluteString,
                    "matched": matched,
                ])
            }
        }
    }
}
