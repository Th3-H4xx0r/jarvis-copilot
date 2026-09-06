import Foundation

/// Client for the server's scheduled-tasks ("crons") API — the web Tasks panel:
/// list/create/update/delete jobs, run/pause/resume them, and read run history
/// plus captured output.
///
/// The envelope keys are not the obvious ones (history → `runs`, output →
/// `outputs: [{filename, content}]`), so every method parses defensively and
/// tolerates a bare list.
struct CronsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/crons` → `{jobs: [...]}`.
    func list() async throws -> [CronJob] {
        let body = try await api.get("/api/crons").object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "jobs")).map(CronJob.init(json:))
    }

    /// `GET /api/crons/history` → `{runs: [...]}` (legacy `entries` tolerated).
    func history(_ jobID: String, limit: Int = 50) async throws -> [CronRun] {
        let response = try await api.get("/api/crons/history",
                                        query: ["job_id": jobID, "limit": "\(limit)"])
        let rows = MoreJSON.mapList(MoreJSON.envelopeList(try response.object(), "runs", "entries"))
        return rows.enumerated().map { CronRun(json: $0.element, index: $0.offset) }
    }

    /// `GET /api/crons/output` → `{outputs: [{filename, content}]}`, joined into
    /// one string. A plain `output` string or a `lines` list also work.
    func output(_ jobID: String, tail: Int = 200) async throws -> String {
        let response = try await api.get("/api/crons/output",
                                         query: ["job_id": jobID, "tail": "\(tail)"])
        let body = try response.object()

        if let direct = body["output"] as? String, !direct.isEmpty { return direct }

        let outputs = MoreJSON.list(body["outputs"])
        if !outputs.isEmpty {
            var chunks: [String] = []
            for item in outputs {
                if let m = item as? JSONObject {
                    let content = MoreJSON.text(m["content"] ?? m["snippet"])
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    let filename = MoreJSON.text(m["filename"])
                    chunks.append(filename.isEmpty ? content : "— \(filename) —\n\(content)")
                } else {
                    chunks.append(MoreJSON.text(item))
                }
            }
            if !chunks.isEmpty { return chunks.joined(separator: "\n\n") }
        }

        if let lines = body["lines"] as? [Any] {
            return lines.map { MoreJSON.text($0) }.joined(separator: "\n")
        }
        if let data = body["data"] as? [Any] {
            return data.map { MoreJSON.text($0) }.joined(separator: "\n")
        }
        return ""
    }

    /// The captured output of one specific run, by its history filename.
    func runOutput(_ jobID: String, filename: String) async throws -> String {
        let response = try await api.get("/api/crons/run",
                                         query: ["job_id": jobID, "filename": filename])
        let body = try response.object()
        if let content = body["content"] ?? body["output"], !(content is NSNull) {
            return MoreJSON.text(content)
        }
        if let lines = body["lines"] as? [Any] {
            return lines.map { MoreJSON.text($0) }.joined(separator: "\n")
        }
        return ""
    }

    func create(_ body: JSONObject) async throws {
        _ = try await api.post("/api/crons/create", json: body)
    }

    /// `body` must include `job_id`.
    func update(_ body: JSONObject) async throws {
        _ = try await api.post("/api/crons/update", json: body)
    }

    func delete(_ jobID: String) async throws {
        _ = try await api.post("/api/crons/delete", json: ["job_id": jobID])
    }

    func run(_ jobID: String) async throws {
        _ = try await api.post("/api/crons/run", json: ["job_id": jobID])
    }

    func pause(_ jobID: String) async throws {
        _ = try await api.post("/api/crons/pause", json: ["job_id": jobID])
    }

    func resume(_ jobID: String) async throws {
        _ = try await api.post("/api/crons/resume", json: ["job_id": jobID])
    }
}
