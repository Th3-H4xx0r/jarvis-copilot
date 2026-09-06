import Foundation

/// Reads and writes the agent's long-term memory files — MEMORY.md ("My Notes")
/// and USER.md ("User Profile") — via `/api/memory`.
///
///     GET  /api/memory       → {memory, user, memory_path, user_path,
///                               memory_mtime, user_mtime}
///     POST /api/memory/write → {section: 'memory'|'user', content}
struct MemoryAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func read() async throws -> MemoryDocuments {
        let response = try await api.get("/api/memory")
        return MemoryDocuments(json: try response.object())
    }

    /// Overwrites one section's file wholesale.
    func write(_ section: MemorySection, content: String) async throws {
        _ = try await api.post("/api/memory/write", json: [
            "section": section.wireKey,
            "content": content,
        ])
    }
}
