import Foundation

/// What a JarvisCopilot pairing QR can carry.
///
/// The accepted forms:
///  1. `jarviscopilot://pair?server=…&code=…[&lan_url=…&cf_id=…&cf_secret=…]`
///  2. `https://host[:port]/pair` → server is the scheme + authority, path dropped
///  3. a bare `https://host[:port]` → used directly as the server URL
///
/// **https only.** The session cookie the claim returns IS the credential, and
/// the Cloudflare service token a QR can carry is a bearer secret; over plain
/// http both go out in the clear to whoever is on the path — and a QR is exactly
/// the vector where the user can't read the URL they're agreeing to. A payload
/// naming an `http://` server is refused here rather than downstream, so no
/// caller can accidentally accept one.
struct PairingPayload: Equatable {
    var server: String?
    /// An on-LAN shortcut the webui may add to the QR alongside the public URL.
    var lanURL: String?
    var code: String?
    var cfClientID: String?
    var cfClientSecret: String?

    /// Returns nil for anything that isn't a recognised pair link or server URL, so the
    /// caller can keep the camera open rather than dismissing on a stray barcode.
    init?(raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let uri = URLComponents(string: text) else { return nil }

        if uri.scheme == "jarviscopilot", uri.host == "pair" {
            let q = Dictionary(uniqueKeysWithValues:
                (uri.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            server = q["server"]
            lanURL = q["lan_url"]
            code = q["code"]
            cfClientID = q["cf_id"]
            cfClientSecret = q["cf_secret"]
            if Self.isPlainHTTP(server) || Self.isPlainHTTP(lanURL) { return nil }
        } else if uri.scheme == "https" {
            guard let host = uri.host else { return nil }
            let port = uri.port.map { ":\($0)" } ?? ""
            server = "https://\(host)\(port)"
        } else {
            return nil
        }

        if server?.isEmpty ?? true, code?.isEmpty ?? true { return nil }
    }

    private static func isPlainHTTP(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }
}
