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

    /// The camera's JPEG preview of a file, or nil when it has none. The A4 answers `getthumbnail` for few
    /// of its clips, but every `.ts` carries its own preview near the start: one range read gets it.
    func thumbnail(_ file: DashcamFile) async -> Data? {
        if let url = thumbnailURL(file),
           let (data, resp) = try? await http.session.data(for: URLRequest(url: url, timeoutInterval: 6)),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           data.count > 100, data.prefix(2) == Data([0xFF, 0xD8]) { return data }
        guard file.isVideo, file.path.lowercased().hasSuffix(".ts") else { return nil }
        let length = Int(min(Int64(DashcamRemux.previewWindow), max(file.size, 0)))
        guard length > 0, let head = try? await http.range(file.path, start: 0, length: length) else { return nil }
        return DashcamRemux.embeddedJPEG(in: head)
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
            if let hit = await probe(c, host: host, timeout: timeout, session: session) { return hit }
        }
        return nil
    }

    /// Asks every family at once — what the setup screen's live "is a dashcam here?" check uses, so a
    /// round costs one timeout, not six. Ties go to the earlier (more common) family.
    static func probeAll(host: String? = nil, timeout: TimeInterval = 1.5,
                         session: URLSession = DashcamHTTP.foreground) async -> (family: DashcamFamily, base: URL)? {
        await withTaskGroup(of: (Int, (family: DashcamFamily, base: URL)?).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask { (i, await probe(c, host: host, timeout: timeout, session: session)) }
            }
            var best: (Int, (family: DashcamFamily, base: URL))?
            for await (i, hit) in group {
                if let hit, best == nil || i < best!.0 { best = (i, hit) }
            }
            return best?.1
        }
    }

    /// Whether this family's camera answers at `host` (its usual address when nil) — one short request.
    static func answers(family: DashcamFamily, host: String? = nil, timeout: TimeInterval = 1.5,
                        session: URLSession = DashcamHTTP.foreground) async -> Bool {
        guard let c = candidates.first(where: { $0.family == family }) else { return false }
        return await probe(c, host: host, timeout: timeout, session: session) != nil
    }

    private static func probe(_ c: Candidate, host: String?, timeout: TimeInterval,
                              session: URLSession) async -> (family: DashcamFamily, base: URL)? {
        guard let base = URL(string: "http://" + (host ?? c.host)) else { return nil }
        let http = DashcamHTTP(base: base, session: session)
        guard let data = try? await http.get(c.path, timeout: timeout) else { return nil }
        switch c.family {
        case .viidure:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["result"] as? NSNumber)?.intValue == 0 else { return nil }
        case .novatek:
            guard String(decoding: data.prefix(64), as: UTF8.self).contains("<") else { return nil }
        default:
            break
        }
        return (c.family, base)
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
