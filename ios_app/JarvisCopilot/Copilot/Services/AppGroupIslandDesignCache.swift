import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Writes Dynamic Island design trees into the shared App Group container so the
/// `JarvisWidget` extension — a SEPARATE process, which cannot make a network
/// call at render time — can read `island/design-<id>.json`.
///
/// The Live Activity `ContentState` has a ~4 KB cap, which a layout tree blows
/// instantly, so the state carries only `{designId, designVersion, data}` and the
/// tree comes from here. Port of `IslandDesignCache` in the Flutter client's
/// `AppDelegate.swift`, minus the method channel.
///
/// `container` is injected so a test can round-trip through a temp directory: on
/// a build without the App Group entitlement (or in the test host) the real
/// container URL is nil and every call is a silent no-op, which is the same
/// degradation the Flutter client had.
struct AppGroupIslandDesignCache: IslandDesignCache {
    let container: URL?
    let fileManager: FileManager
    /// Downloads remote images referenced by a design. Nil in tests.
    let images: IslandImagePrefetching?

    init(container: URL? = JarvisShared.defaultContainer(),
         fileManager: FileManager = .default,
         images: IslandImagePrefetching? = IslandImageCache()) {
        self.container = container
        self.fileManager = fileManager
        self.images = images
    }

    private var directory: URL? {
        JarvisShared.islandDirectory(container: container, fileManager: fileManager)
    }

    func cacheDesigns(_ payloads: [JSONObject]) async {
        guard let directory else { return }
        for payload in payloads {
            guard let id = payload["id"] as? String, !id.isEmpty,
                  let json = payload["json"] as? String else { continue }
            let file = directory.appendingPathComponent(JarvisShared.designFileName(id))
            do {
                // `.atomic` so the widget never reads a half-written tree — it
                // renders on iOS's schedule, not ours.
                try Data(json.utf8).write(to: file, options: .atomic)
            } catch {
                // A failed write means the island silently falls back to the
                // built-in view; the App Group entitlement or a full disk is the
                // usual cause, and neither is guessable from the symptom.
                JcLog.dropped(JcLog.services, "island design cache write", error)
                continue
            }
            images?.prefetch(IslandImageCache.urls(inDesign: json))
        }
    }

    func clearCache() async {
        guard let directory else { return }
        do {
            let items = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            for item in items where item.lastPathComponent.hasPrefix("design-") {
                try fileManager.removeItem(at: item)
            }
        } catch {
            JcLog.dropped(JcLog.services, "island design cache clear", error)
        }
    }

    /// The JSON currently on disk for a design (diagnostics + tests).
    func cachedJSON(id: String) -> String? {
        guard let directory else { return nil }
        let file = directory.appendingPathComponent(JarvisShared.designFileName(id))
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Pre-downloading remote island images, behind a protocol so the cache can be
/// tested without touching the network.
protocol IslandImagePrefetching: Sendable {
    func prefetch(_ urls: [String])
}

/// Downloads remote island image URLs into the App Group so the widget extension
/// (which cannot fetch at render time) renders them from disk, including offline
/// once cached.
///
/// Best-effort and idempotent: an already-cached URL is skipped and a failed
/// download just leaves the leaf showing its fallback.
struct IslandImageCache: IslandImagePrefetching {
    let container: URL?
    let fileManager: FileManager
    let session: URLSession

    init(container: URL? = JarvisShared.defaultContainer(),
         fileManager: FileManager = .default,
         session: URLSession = .shared) {
        self.container = container
        self.fileManager = fileManager
        self.session = session
    }

    /// Deterministic filename for a URL. MUST match `JCImageCache.fileName` in
    /// `JarvisWidget/JarvisDesignRenderer.swift` — the two processes agree on the
    /// name and never talk.
    static func fileName(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func prefetch(_ urls: [String]) {
        guard let dir = JarvisShared.islandImageDirectory(container: container,
                                                          fileManager: fileManager) else { return }
        for raw in Set(urls) {
            guard Self.isFetchable(raw), let url = URL(string: raw) else { continue }
            let file = dir.appendingPathComponent(Self.fileName(for: raw))
            if fileManager.fileExists(atPath: file.path) { continue }
            session.dataTask(with: url) { data, response, error in
                if let error {
                    JcLog.dropped(JcLog.services, "island image prefetch", error)
                    return
                }
                // An error page is still a 200-shaped body to `dataTask`; caching
                // one would pin the failure until the URL changes.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    JcLog.services.warning("island image prefetch: HTTP \(http.statusCode)")
                    return
                }
                guard let data, !data.isEmpty else { return }
                #if canImport(UIKit)
                guard UIImage(data: data) != nil else { return }
                #endif
                do { try data.write(to: file, options: .atomic) }
                catch { JcLog.dropped(JcLog.services, "island image write", error) }
            }.resume()
        }
    }

    /// https only. A design comes from the paired server, but the URLs inside it
    /// are strings the server merely relayed; a plaintext fetch would tell
    /// anyone on the path which images this phone renders, and ATS would refuse
    /// it in a release build anyway.
    static func isFetchable(_ raw: String) -> Bool {
        guard raw.hasPrefix("https://"), let url = URL(string: raw) else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// The prop names the widget's renderer actually resolves as a remote image
    /// (`JCDesignRenderer`, `case "image"`). Nothing else in a tree is fetched,
    /// so nothing else is harvested.
    static let imageSourceKeys: Set<String> = ["source"]

    /// Remote image URLs in a design TREE.
    ///
    /// Only literal `source` props of image nodes, https only. Harvesting every
    /// http(s) string in the document (what this used to do) turned any URL a
    /// payload happened to mention — a link in a label, a webhook in a
    /// condition — into a request from the phone.
    static func urls(inDesign jsonString: String) -> [String] {
        harvest(jsonString) { key, _ in imageSourceKeys.contains(key) }
    }

    /// Remote image URLs in a pushed DATA payload.
    ///
    /// The payload is `sourceKey: value` — a design binds an image's `source` to
    /// one of these keys BY NAME, so the key here carries no type information
    /// and every https value is a candidate. The https rule is what bounds it.
    static func urls(inData jsonString: String) -> [String] {
        harvest(jsonString) { _, _ in true }
    }

    /// Walk a JSON document, offering every string to `accept(key, value)`.
    /// Strings not under a key (bare array elements at the root) are skipped:
    /// the renderer has no way to reach them.
    private static func harvest(_ jsonString: String,
                                accept: (String, String) -> Bool) -> [String] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []
        func walk(_ value: Any, key: String?) {
            if let text = value as? String {
                guard let key, accept(key, text), isFetchable(text) else { return }
                out.append(text)
            } else if let list = value as? [Any] {
                // An array under `source` is still that key's value.
                for item in list { walk(item, key: key) }
            } else if let map = value as? [String: Any] {
                for (childKey, item) in map { walk(item, key: childKey) }
            }
        }
        walk(object, key: nil)
        return out
    }
}
