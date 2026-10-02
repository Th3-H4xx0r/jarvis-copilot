import Foundation
@testable import JarvisCopilot

/// Serves canned camera/server replies to a URLSession. Handlers are matched in order on the
/// request URL string (path + query); the first whose key the URL contains wins.
final class DashcamStubProtocol: URLProtocol {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    nonisolated(unsafe) static var routes: [(String, (URLRequest) -> Reply)] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() { lock.lock(); routes = []; seen = []; lock.unlock() }
    static func on(_ key: String, _ reply: @escaping (URLRequest) -> Reply) { lock.lock(); routes.append((key, reply)); lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [DashcamStubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let url = request.url?.absoluteString ?? ""
        let handler = Self.routes.first { url.contains($0.0) }?.1
        Self.lock.unlock()
        let reply = handler?(request) ?? Reply(status: 404)
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum DashcamSamples {
    /// Built by `dashcam_fake.py` (three 10-field lines from 2026/10/01 15:40:00 camera-local,
    /// 41.8781 N, 87.6298 W, 50/51/52 km/h, heading 90). The Python parser reads the first as
    /// [1790869200.0, 41.8781, -87.6298, 13.89 m/s, 90.0].
    static let normalBlock = Data(base64Encoded: "AAABsGZyZWUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAyMDI2LzEwLzAxIDE1OjQwOjAwIE46NDE1Mi42ODYwIFc6MDg3MzcuNzg4MCA1MC4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEyMDI2LzEwLzAxIDE1OjQwOjAxIE46NDE1Mi42ODYwIFc6MDg3MzcuNzgyMCA1MS4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIyMDI2LzEwLzAxIDE1OjQwOjAyIE46NDE1Mi42ODYwIFc6MDg3MzcuNzc2MCA1Mi4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACYmJiYAAAGw")!
    static let fhBlock = Data(base64Encoded: "AAAB8GZyZWVGSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAyMDI2LzEwLzAxIDE1OjQwOjAwIE46NDE1Mi42ODYwIFc6MDg3MzcuNzg4MCA1MC4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAyMDI2LzEwLzAxIDE1OjQwOjAxIE46NDE1Mi42ODYwIFc6MDg3MzcuNzgyMCA1MS4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAyMDI2LzEwLzAxIDE1OjQwOjAyIE46NDE1Mi42ODYwIFc6MDg3MzcuNzc2MCA1Mi4wIFg6MC4wMSBZOi0wLjAyIFo6MC45OCBBOjkwLjAgSDoxODIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAmJiYmAAAB8A==")!

    /// 20:40:00 UTC = 15:40:00 in the camera's UTC-5 clock.
    static let clipStart = Date(timeIntervalSince1970: 1_790_887_200)
    static let tz = -5 * 3600
    static let zone = TimeZone(secondsFromGMT: -5 * 3600)!

    static func json(_ obj: Any) -> DashcamStubProtocol.Reply {
        .init(status: 200, headers: ["Content-Type": "application/json"],
              body: try! JSONSerialization.data(withJSONObject: obj))
    }

    /// A Range-honouring reply over `data`, like the camera's file server.
    static func ranged(_ data: Data) -> (URLRequest) -> DashcamStubProtocol.Reply {
        { req in
            guard let r = req.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") else {
                return .init(status: 200, headers: ["Content-Length": "\(data.count)"], body: data)
            }
            let parts = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let lo = Int(parts[0]) ?? 0
            let hi = min(data.count - 1, Int(parts.count > 1 ? parts[1] : "") ?? data.count - 1)
            return .init(status: 206, headers: ["Content-Range": "bytes \(lo)-\(hi)/\(data.count)"],
                         body: data.subdata(in: lo..<(hi + 1)))
        }
    }
}
