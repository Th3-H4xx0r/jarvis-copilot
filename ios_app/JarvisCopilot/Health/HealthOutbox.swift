import Foundation

/// A folder of JSON files: a store's copy of what it holds, readable with no signal.
struct JSONFolder {
    let directory: URL
    /// How a failed write reads in the log ("habit file").
    let label: StaticString

    init(_ directory: URL, label: StaticString) {
        self.directory = directory
        self.label = label
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(value).write(to: url(name), options: .atomic)
        } catch {
            JcLog.dropped(JcLog.devices, label, error)
        }
    }

    func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

/// Changes made on the phone, waiting for Jarvis Health: kept on disk (`queue.json`), so a failed
/// send loses nothing, and sent in order.
@MainActor
final class HealthOutbox<Op: Codable & Equatable> {
    /// What the server answers when it will never take a change (deleted on the server, a bad
    /// field). An expired session (401/403), a timeout (408) or a rate limit (429) is not one of
    /// them: those changes wait and go later.
    static var refusals: Set<Int> { [400, 404, 409, 410, 422] }

    private(set) var ops: [Op]
    private let folder: JSONFolder
    /// How a failed send reads in the log ("habit sync").
    private let label: StaticString
    private var flushing: Task<Void, Never>?

    /// A send is under way: the first change may already have reached the server.
    var isSending: Bool { flushing != nil }

    init(_ folder: JSONFolder, label: StaticString) {
        self.folder = folder
        self.label = label
        ops = folder.read([Op].self, "queue") ?? []
    }

    func append(_ op: Op) {
        ops.append(op)
        save()
    }

    func removeAll(where shouldRemove: (Op) -> Bool) {
        ops.removeAll(where: shouldRemove)
        save()
    }

    /// Send what is waiting, in order. A refusal drops that change (`refused` says why); anything
    /// else (offline, a 5xx, a 401) stops and keeps the rest. A second call waits on the first.
    func flush(send: @escaping (Op) async throws -> Void, refused: @escaping (Int, String) -> Void) async {
        if let flushing { return await flushing.value }
        let task = Task {
            while let op = self.ops.first {
                do {
                    try await send(op)
                } catch APIError.http(let status, let message) where Self.refusals.contains(status) {
                    refused(status, message)
                } catch {
                    JcLog.dropped(JcLog.devices, self.label, error)
                    return
                }
                // Only this loop removes from the front, so the first is still the one just sent.
                if self.ops.first == op { self.ops.removeFirst() }
                self.save()
            }
        }
        flushing = task
        await task.value
        flushing = nil
    }

    private func save() { folder.write(ops, "queue") }
}
