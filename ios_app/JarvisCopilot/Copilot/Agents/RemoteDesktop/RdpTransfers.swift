import Foundation
import UniformTypeIdentifiers

/// Files both ways in a Remote Desktop session:
/// - `Documents/Jarvis Transfer` is redirected to the PC as the drive "Jarvis iPhone" (rdpdr), so
///   anything put here shows in Explorer and anything saved there lands here (Files app too);
/// - "Send to PC" hands a file to Holo Drop, which lands it in Holo Drop's PC folder.
enum RdpTransfers {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Jarvis Transfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        let size: Int64
        let modified: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// What's in the transfer folder, newest first.
    static func items(in dir: URL = folder) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory != true else { return nil }
            return Item(url: u, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    /// Copies a picked file in, never overwriting: "photo.jpg", "photo 2.jpg", …
    @discardableResult
    static func copyIn(_ source: URL, name: String? = nil, to dir: URL = folder) throws -> URL {
        let target = uniqueURL(for: name ?? source.lastPathComponent, in: dir)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func write(_ data: Data, name: String, to dir: URL = folder) throws -> URL {
        let target = uniqueURL(for: name, in: dir)
        try data.write(to: target)
        return target
    }

    static func uniqueURL(for name: String, in dir: URL) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-")
        var url = dir.appendingPathComponent(clean)
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Hands the file to Holo Drop for the PC (saved in its Holo Drop folder).
    @MainActor
    static func sendToPC(_ url: URL, deviceId: String) async throws {
        guard let client = HoloDropReceiver.shared.client else { throw APIError.notPaired }
        guard let pc = try await client.devices().first(where: { $0.id == deviceId }) else {
            throw APIError.badResponse("Holo Drop doesn't see the PC right now")
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : "file"
        _ = try await client.send(.file(url, name: url.lastPathComponent, mime: mime, kind: kind), to: pc,
                                  action: .save, position: nil)
    }
}
