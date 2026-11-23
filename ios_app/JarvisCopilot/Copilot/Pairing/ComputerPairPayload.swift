import Foundation

/// What a computer's "Pair with your iPhone" QR carries — the Windows Jarvis app and the Mac
/// app draw it from jc-client's `pair_qr_start` (contract:
/// docs/superpowers/plans/2026-11-23-qr-pairing.md):
///
/// `jarvis://pair-computer?v=1&host=<LAN IPv4>&port=<int>&key=<base64url, 32 bytes>&name=<name>&os=<windows|macos>`
///
/// The phone answers by sealing a fresh pairing code with `key` and posting it to
/// `http://host:port/pair` (`ComputerPairSeal`, `ComputerPairFlow`).
struct ComputerPairPayload: Identifiable, Equatable, Sendable {
    enum OS: String, Sendable {
        case windows, macos

        /// How the confirm sheet names it: "Pair Gaming PC (Windows)?".
        var label: String { self == .windows ? "Windows" : "Mac" }
    }

    let host: String
    let port: Int
    /// The one-time AES-256 key, 32 bytes.
    let key: Data
    let name: String
    let os: OS

    var id: String { "\(host):\(port)/\(key.base64EncodedString())" }
    /// Plain http on purpose: the body is sealed with `key`, and the listener lives on the
    /// home network for ten minutes, so there is no certificate to check.
    var pairURL: URL { URL(string: "http://\(host):\(port)/pair")! }
    var title: String { "Pair \(name) (\(os.label))?" }

    /// Nil for anything that isn't a well-formed v1 computer pairing link.
    static func parse(_ raw: String) -> ComputerPairPayload? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "jarvis",
              comps.host?.lowercased() == "pair-computer" else { return nil }
        var query: [String: String] = [:]
        for item in comps.percentEncodedQueryItems ?? [] {
            // Python's urlencode (jc-client) writes a space as "+"; a real "+" arrives as %2B.
            let value = (item.value ?? "").replacingOccurrences(of: "+", with: " ")
            query[item.name] = value.removingPercentEncoding ?? value
        }
        guard query["v"] == "1",
              let host = query["host"], isHomeNetworkIPv4(host),
              let port = query["port"].flatMap({ Int($0) }), (1...65535).contains(port),
              let key = query["key"].flatMap(decodeBase64URL), key.count == 32,
              let os = query["os"].flatMap({ OS(rawValue: $0.lowercased()) }) else { return nil }
        let cleaned = String(String.UnicodeScalarView((query["name"] ?? "").unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }))
        let name = String(jcTrim(cleaned).prefix(64))
        guard !name.isEmpty else { return nil }
        return ComputerPairPayload(host: host, port: port, key: key, name: name, os: os)
    }

    /// A dotted-quad IPv4 address on a home network: 10/8, 172.16/12, 192.168/16, link-local
    /// 169.254/16 or 100.64/10 (Tailscale). The phone sends a live pairing code to this
    /// address, so a QR naming one out on the internet is refused rather than trusted.
    static func isHomeNetworkIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let value = Int(part), value <= 255 else { return false }
            octets.append(value)
        }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.hasSuffix("=") { b64.removeLast() }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}
