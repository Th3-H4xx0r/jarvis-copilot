import Foundation

/// Reads a bounded tail window of an active-profile server log file
/// (`GET /api/logs`). Parses defensively so a shape change can't break the
/// screen.
///
/// The Flutter client polls this endpoint every 5 s when auto-refresh is on —
/// there is no log *stream* on the server, so neither is there one here.
struct ServerLogsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// The last `tail` lines of `file` (one of `serverLogFiles`).
    func tail(file: String = "agent", tail: Int = 1000) async throws -> ServerLogTail {
        let response = try await api.get("/api/logs",
                                         query: ["file": file, "tail": "\(tail)"])
        return ServerLogTail(json: try response.object(),
                             requestedFile: file, requestedTail: tail)
    }
}
