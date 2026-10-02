import Foundation

/// Everything Jarvis does with a camera, whatever its SoC family. One implementation per
/// family; parsing lives in static functions so it is testable without a network.
protocol DashcamCamera: Sendable {
    var family: DashcamFamily { get }
    var http: DashcamHTTP { get }

    func info() async throws -> DashcamCameraInfo
    /// Every file on the card; `timeZone` is the zone the camera's clock runs in (stamps are local).
    func files(timeZone: TimeZone) async throws -> [DashcamFile]
    func fileURL(_ file: DashcamFile) -> URL
    func thumbnailURL(_ file: DashcamFile) -> URL?
    func setTime(_ date: Date, timeZone: TimeZone) async throws
    func isRecording() async throws -> Bool
    func setRecording(_ on: Bool) async throws
    func lock() async throws
    /// Takes a photo; returns its path on the card when the camera says.
    func snapshot() async throws -> String?
    func settings() async throws -> [DashcamSettingItem]
    func set(_ name: String, _ value: String) async throws
    func sdInfo() async throws -> DashcamSDInfo
    func format() async throws
    func delete(_ file: DashcamFile) async throws
    func setWiFi(ssid: String?, password: String?) async throws
    /// Playback mode (Viidure). No-op where the family has none.
    func playback(_ enter: Bool) async throws
    func gps(_ file: DashcamFile, tzOffset: Int) async throws -> [DashcamFix]
    func thumbnail(_ file: DashcamFile) async -> Data?
}

extension DashcamCamera {
    func fileURL(_ file: DashcamFile) -> URL { http.url(file.path) }

    /// The camera's JPEG preview of a file, or nil when it has none.
    func thumbnail(_ file: DashcamFile) async -> Data? {
        guard let url = thumbnailURL(file),
              let (data, resp) = try? await http.session.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              data.count > 100, data.prefix(2) == Data([0xFF, 0xD8]) else { return nil }
        return data
    }
}

/// Finds the camera on the current Wi‑Fi: each family's detector at its usual address, or at
/// `host` when one is pinned (a camera with a non-default address, or the fake camera).
enum DashcamDetect {
    struct Candidate: Sendable {
        let family: DashcamFamily
        let host: String
        let path: String
    }

    static let candidates: [Candidate] = [
        .init(family: .viidure, host: "192.168.169.1", path: "/app/getdeviceattr"),
        .init(family: .novatek, host: "192.168.1.254", path: "/?custom=1&cmd=3029"),
        .init(family: .hisilicon, host: "192.168.0.1", path: "/cgi-bin/hisnet/getwifi.cgi?"),
        .init(family: .allwinner, host: "192.168.10.1:8082", path: "/api/getdeviceinfo/?custom=1&cmd=2001"),
        .init(family: .mstar, host: "192.72.1.1", path: "/cgi-bin/Config.cgi?action=get&property=Camera.Menu.*"),
        .init(family: .huiying, host: "192.168.201.1", path: "/?cmd=302&param=network_ap"),
    ]

    /// Tries the families one after another (each with a short timeout) and returns the first that answers.
    static func probe(host: String? = nil, timeout: TimeInterval = 2.5,
                      session: URLSession = DashcamHTTP.foreground) async -> (family: DashcamFamily, base: URL)? {
        for c in candidates {
            guard let base = URL(string: "http://" + (host ?? c.host)) else { continue }
            let http = DashcamHTTP(base: base, session: session)
            guard let data = try? await http.get(c.path, timeout: timeout) else { continue }
            switch c.family {
            case .viidure:
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["result"] as? NSNumber)?.intValue == 0 else { continue }
            case .novatek:
                guard String(decoding: data.prefix(64), as: UTF8.self).contains("<") else { continue }
            default:
                break
            }
            return (c.family, base)
        }
        return nil
    }

    static func camera(family: DashcamFamily, base: URL, session: URLSession = DashcamHTTP.foreground) -> DashcamCamera? {
        let http = DashcamHTTP(base: base, session: session)
        switch family {
        case .viidure: return ViidureCamera(http: http)
        case .novatek: return NovatekCamera(http: http)
        default: return nil
        }
    }
}
