import Foundation

/// Plain HTTP to the camera. The camera is a small web server on its own Wi‑Fi: no TLS, no
/// auth, slow when it is busy recording. Requests never fall back to cellular — the camera's
/// address only exists on its own network.
struct DashcamHTTP: Sendable {
    let base: URL
    var session: URLSession = DashcamHTTP.foreground

    static let foreground: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.allowsCellularAccess = false
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 20
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func url(_ pathAndQuery: String) -> URL {
        // Paths come from the camera's own listing; only spaces and the odd non-ASCII name need escaping.
        let escaped = pathAndQuery.addingPercentEncoding(withAllowedCharacters: DashcamHTTP.allowed) ?? pathAndQuery
        return URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + escaped)
            ?? base.appendingPathComponent(pathAndQuery)
    }

    private static let allowed: CharacterSet = {
        var s = CharacterSet.urlPathAllowed
        s.insert(charactersIn: "?&=%:")
        return s
    }()

    func get(_ pathAndQuery: String, timeout: TimeInterval = 6) async throws -> Data {
        var req = URLRequest(url: url(pathAndQuery), timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw DashcamError.http(http.statusCode) }
        return data
    }

    /// Total size of a file, from a one-byte range read (HEAD as a fallback).
    func size(_ path: String) async throws -> Int64 {
        var req = URLRequest(url: url(path), timeoutInterval: 6)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, http) = try await send(req)
        if http.statusCode == 206, let total = DashcamHTTP.rangeTotal(http.value(forHTTPHeaderField: "Content-Range")) {
            return total
        }
        var head = URLRequest(url: url(path), timeoutInterval: 6)
        head.httpMethod = "HEAD"
        let (_, h2) = try await send(head)
        guard h2.statusCode == 200, h2.expectedContentLength > 0 else { throw DashcamError.http(h2.statusCode) }
        return h2.expectedContentLength
    }

    func range(_ path: String, start: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var req = URLRequest(url: url(path), timeoutInterval: 8)
        req.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, http) = try await send(req)
        switch http.statusCode {
        case 206: return data
        case 200:   // server ignored Range
            let lo = Int(min(Int64(data.count), start))
            return data.subdata(in: lo..<min(data.count, lo + length))
        default: throw DashcamError.http(http.statusCode)
        }
    }

    static func rangeTotal(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw DashcamError.badReply("not HTTP") }
            return (data, http)
        } catch let e as DashcamError {
            throw e
        } catch {
            throw DashcamError.notConnected
        }
    }
}
