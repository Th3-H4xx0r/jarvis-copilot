import Foundation

/// What the Jarvis Ball's setup screen encodes in its QR code:
/// `jarviscopilot://device-setup?v=1&kind=jarvis_ball&ssid=Jarvis-64D5&pw=…&id=<mac>`.
/// The passphrase is new every time the ball enters setup mode and only ever shown on its screen.
struct BallSetupCode: Identifiable, Equatable, Sendable {
    let ssid: String
    let passphrase: String
    let mac: String

    var id: String { mac }
    /// "64D5" — the same suffix the ball uses for its hotspot and its name on the server.
    var suffix: String { String(ssid.split(separator: "-").last ?? Substring(ssid)) }
    var ballName: String { "Jarvis Ball \(suffix)" }

    static func parse(_ raw: String) -> BallSetupCode? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "jarviscopilot", comps.host == "device-setup" else { return nil }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["v"] == "1", query["kind"] == "jarvis_ball",
              let ssid = query["ssid"], !ssid.isEmpty,
              let pw = query["pw"], pw.count >= 8,
              let mac = query["id"], mac.count == 12 else { return nil }
        return BallSetupCode(ssid: ssid, passphrase: pw, mac: mac.lowercased())
    }
}
