import Foundation

/// The byte cache behind chat images: `/api/media` is cookie-gated, so the bytes come through
/// `JarvisAPI` rather than a plain `AsyncImage`, and a scrolled-away image must not be refetched
/// when it comes back. (`ChatMedia` turns the agent's media into markdown images.)

extension ChatMedia {
    /// The API base the rewrite uses in production. Empty when unpaired, which
    /// leaves a root-relative `/api/media?path=…` — still resolvable by
    /// ``ChatImageCache``, which routes relative paths through `JarvisAPI`.
    @MainActor
    static func apiBase(_ api: JarvisAPI = .shared) -> String {
        api.credentials.baseURL?.absoluteString ?? ""
    }
}

// MARK: - Byte cache

/// In-memory cache of chat image bytes, fetched through `JarvisAPI` so the
/// session cookie (and any Cloudflare Access token) goes with the request —
/// `/api/media` is cookie-gated and `AsyncImage` would get a 401.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its
/// own, which matters because a long thread of generated images is exactly the
/// case that would otherwise get the app jetsammed. Nothing is written to disk —
/// a chat image is cheap to refetch and the bytes may be private.
@MainActor
final class ChatImageCache {

    static let shared = ChatImageCache()

    /// ~48 MB of decoded-image source bytes is several screens' worth.
    static let costLimit = 48 * 1024 * 1024
    /// Anything bigger is a mistake (or a video someone mislabelled); the chip
    /// fallback is better than a multi-hundred-megabyte allocation.
    static let maxBytes = 24 * 1024 * 1024

    private let api: JarvisAPI
    private let cache = NSCache<NSString, NSData>()
    /// De-dupes concurrent requests for the same URL: a `LazyVStack` can mount
    /// the same row twice while scrolling.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(api: JarvisAPI = .shared) {
        self.api = api
        cache.totalCostLimit = Self.costLimit
    }

    /// Cached bytes, or nil if nothing has been fetched for `source` yet.
    func cached(_ source: String) -> Data? { cache.object(forKey: source as NSString) as Data? }

    /// Fetch (or reuse) the bytes behind a chat image. Nil on any failure — the
    /// caller shows the broken-image chip, exactly as the Flutter renderer does.
    func bytes(_ source: String) async -> Data? {
        if let hit = cached(source) { return hit }
        if let running = inFlight[source] { return await running.value }

        let api = self.api
        let (url, absolute) = resolve(source)
        let task = Task<Data?, Never> {
            try? await api.bytes(url, absolute: absolute)
        }
        inFlight[source] = task
        let data = await task.value
        inFlight[source] = nil
        guard let data, !data.isEmpty, data.count <= Self.maxBytes else { return nil }
        cache.setObject(data as NSData, forKey: source as NSString, cost: data.count)
        return data
    }

    /// The URL to actually fetch, and whether it is absolute.
    ///
    /// A root-relative `/api/media?path=…` is joined onto the paired base HERE
    /// rather than handed to `JarvisAPI.get`: that builds the URL through
    /// `URLComponents.path`, which percent-encodes the `?` into the path and
    /// turns the whole thing into a 404. Either way the credential headers go
    /// with it — `bytes(absolute:)` sets them on both paths.
    private func resolve(_ source: String) -> (url: String, absolute: Bool) {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return (source, true) }
        guard let base = api.credentials.baseURL else { return (source, false) }
        var joined = base.absoluteString
        if joined.hasSuffix("/") { joined.removeLast() }
        return (joined + (source.hasPrefix("/") ? source : "/" + source), true)
    }
}
