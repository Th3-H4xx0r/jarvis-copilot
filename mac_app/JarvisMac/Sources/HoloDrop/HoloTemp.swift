import Foundation

/// Holo Drop's temporary copies — pasted images, shared files copied in, folders zipped for
/// upload, received files kept for "open", LAN uploads — all live in `HoloDrop-*` folders of
/// the temporary directory. Swept after a day at launch; a sent item's copy goes once its drop
/// has settled. Never touches anything outside those folders.
enum HoloTemp {
    static let prefix = "HoloDrop-"
    /// Received files for "open" sit one folder per drop in here; it's swept by its children.
    static let inbox = "HoloDrop-inbox"

    static func sweep(_ root: URL = FileManager.default.temporaryDirectory, maxAge: TimeInterval = 24 * 3600,
                      now: Date = Date()) {
        let fm = FileManager.default
        func old(_ u: URL) -> Bool {
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { now.timeIntervalSince($0) > maxAge } ?? false
        }
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in entries where u.lastPathComponent.hasPrefix(prefix) {
            if u.lastPathComponent == inbox {
                let drops = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for d in drops where old(d) { try? fm.removeItem(at: d) }
            } else if old(u) {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// Deletes the temporary copies an item was made of (each file's own `HoloDrop-*` folder
    /// directly under `root`); his own files are left alone.
    static func release(_ item: HoloItem?, root: URL = FileManager.default.temporaryDirectory) {
        guard case .files(let urls) = item else { return }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        for u in urls {
            let folder = u.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard folder.deletingLastPathComponent().path == base,
                  folder.lastPathComponent.hasPrefix(prefix), folder.lastPathComponent != inbox else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
