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

    /// Total size of a file, from a one-byte range read (the length header when Range is ignored).
    func size(_ path: String) async throws -> Int64 {
        var req = URLRequest(url: url(path), timeoutInterval: 6)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, http) = try await partial(req, limit: 1, prefixOK: false)
        if http.statusCode == 206, let total = DashcamHTTP.rangeTotal(http.value(forHTTPHeaderField: "Content-Range")) {
            return total
        }
        guard http.statusCode == 200, http.expectedContentLength > 0 else { throw DashcamError.http(http.statusCode) }
        return http.expectedContentLength
    }

    func range(_ path: String, start: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var req = URLRequest(url: url(path), timeoutInterval: 8)
        req.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, http) = try await partial(req, limit: length, prefixOK: start == 0)
        switch http.statusCode {
        case 206: return data
        case 200 where start == 0: return data           // Range ignored, but the start is the start
        case 200: throw DashcamError.badReply("the camera ignores byte ranges")
        default: throw DashcamError.http(http.statusCode)
        }
    }

    /// The last `count` bytes and the file's total size in one suffix-range request (size + range when the
    /// camera doesn't do suffix ranges).
    func tail(_ path: String, count: Int) async throws -> (data: Data, total: Int64) {
        var req = URLRequest(url: url(path), timeoutInterval: 8)
        req.setValue("bytes=-\(count)", forHTTPHeaderField: "Range")
        if let (data, http) = try? await partial(req, limit: count, prefixOK: false), http.statusCode == 206,
           let total = DashcamHTTP.rangeTotal(http.value(forHTTPHeaderField: "Content-Range")), data.count == min(Int64(count), total) {
            return (data, total)
        }
        let total = try await size(path)
        guard total >= Int64(count) else { return (Data(), total) }
        return (try await range(path, start: total - Int64(count), length: count), total)
    }

    static func rangeTotal(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// A ranged read. A camera that ignores Range answers 200 with the whole clip — hundreds of MB that
    /// used to come down for a one-byte size probe (seconds per clip on "Reading GPS"). The body stops at
    /// `limit` bytes, and a 200 is dropped unread unless the caller wanted the file's start anyway.
    private func partial(_ req: URLRequest, limit: Int, prefixOK: Bool) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { bytes.task.cancel(); throw DashcamError.badReply("not HTTP") }
            guard http.statusCode == 206 || (http.statusCode == 200 && prefixOK) else { bytes.task.cancel(); return (Data(), http) }
            var data = Data()
            data.reserveCapacity(min(limit, 4 << 20))
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
            bytes.task.cancel()
            return (data, http)
        } catch let e as DashcamError {
            throw e
        } catch {
            throw DashcamError.notConnected
        }
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
