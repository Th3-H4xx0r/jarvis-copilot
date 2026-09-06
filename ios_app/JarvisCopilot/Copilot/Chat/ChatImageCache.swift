import Foundation

/// The `MEDIA:` pre-pass and the byte cache behind chat images.
///
/// Both halves of `widgets/markdown_stream.dart`'s image handling:
///
///  * `_rewriteMedia` — the agent emits bare `MEDIA:<ref>` directives (the same
///    stash/restore the web UI's `renderMd` does in `static/ui.js`); markdown
///    knows nothing about them, so they are rewritten into real markdown images
///    BEFORE the renderer ever sees the text.
///  * the `_urlCache` behind `imageBuilder` — `/api/media` is cookie-gated, so
///    the bytes come through `JarvisAPI` rather than a plain `AsyncImage`, and a
///    scrolled-away image must not be refetched when it comes back.

// MARK: - MEDIA: → markdown

enum ChatMedia {

    /// Extensions rendered inline, mirroring the web UI's `_IMAGE_EXTS`.
    static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif"]

    /// Dart's `Uri.encodeComponent` allow-list, so a path with spaces or `&`
    /// survives the round trip exactly as the Flutter client sent it.
    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()

    /// Rewrite every `MEDIA:<ref>` token into markdown.
    ///
    /// Pure — `base` is passed in rather than read from `JarvisAPI` — so the
    /// three cases can be asserted without a pairing:
    ///
    ///  * `http(s)` → `![image](url)`, whatever its extension (extensionless CDN
    ///    paths still resolve, matching the web UI);
    ///  * a local/absolute path that LOOKS like an image → the cookie-gated
    ///    `<base>/api/media?path=…`;
    ///  * anything else → left as plain text, i.e. a tappable link at most. A PDF
    ///    rendered as a broken image chip would be a lie.
    static func rewrite(_ input: String, base: String) -> String {
        // Cheap bail-out: the overwhelming majority of turns carry no media, and
        // this runs on every token of a streaming reply.
        guard input.contains("MEDIA:") else { return input }
        guard let regex = try? NSRegularExpression(pattern: "MEDIA:([^\\s)\\]]+)") else {
            return input
        }
        let text = input as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: cursor,
                                                length: match.range.location - cursor))
            let whole = text.substring(with: match.range)
            let ref = match.range(at: 1).location == NSNotFound
                ? "" : text.substring(with: match.range(at: 1))
            out += replacement(for: ref, whole: whole, base: base)
            cursor = match.range.location + match.range.length
        }
        out += text.substring(from: cursor)
        return out
    }

    /// The API base the rewrite uses in production. Empty when unpaired, which
    /// leaves a root-relative `/api/media?path=…` — still resolvable by
    /// ``ChatImageCache``, which routes relative paths through `JarvisAPI`.
    @MainActor
    static func apiBase(_ api: JarvisAPI = .shared) -> String {
        api.credentials.baseURL?.absoluteString ?? ""
    }

    private static func replacement(for ref: String, whole: String, base: String) -> String {
        guard !ref.isEmpty else { return whole }
        let lower = ref.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return "![image](\(ref))"
        }
        // Strip a query string before the extension test (e.g. `?w=512`).
        let path = ref.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ref
        guard let dot = path.lastIndex(of: "."),
              imageExtensions.contains(String(path[path.index(after: dot)...]).lowercased())
        else { return ref }
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? ref
        return "![image](\(base)/api/media?path=\(encoded))"
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
