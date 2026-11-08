import CoreGraphics
import Foundation
import LinkPresentation

/// The agent's `MEDIA:<ref>` directives (the same stash/restore the web UI's `renderMd` does in
/// `static/ui.js`) and the server's media paths, as markdown images. Pure, so the iPhone and the
/// Mac compile this one file (mac_app/JarvisMac/project.yml).

enum ChatMedia {

    /// Extensions rendered inline: the server's `_LOCAL_IMAGE_EXTS` (agent/chat_media.py) and `ico`.
    static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif", "tif", "tiff", "heic", "heif"]

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
    static func rewrite(_ input: String, base: String = "") -> String {
        // Cheap bail-out: the overwhelming majority of turns carry no media, and
        // this runs on every token of a streaming reply.
        guard input.contains("MEDIA:") || input.contains("![") || input.hasSuffix("M")
                || input.hasSuffix("ME") || input.hasSuffix("MED") || input.hasSuffix("MEDI")
        else { return input }
        let input = localImages(holdPartial(input), base: base)
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

    /// A half-typed image token at the very end of a streaming reply waits
    /// until it is whole, so a raw `MEDIA:/root/wor…` path never flashes. A
    /// `MEDIA:` ref that already ends in an image extension counts as whole.
    static func holdPartial(_ text: String) -> String {
        let ns = text as NSString
        guard let match = partialPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return text }
        let token = ns.substring(with: match.range(at: 2))
        if token.hasPrefix("MEDIA:") {
            let ref = String(token.dropFirst(6))
            let lower = ref.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                // A web address with a path past its host is whole enough to show
                // (CDN images often have no extension); a bare host isn't.
                if ref.components(separatedBy: "://").dropFirst().joined().contains("/") { return text }
            } else {
                let path = ref.split(separator: "?").first.map(String.init) ?? ""
                if let dot = path.lastIndex(of: "."),
                   wholeExtensions.contains(path[path.index(after: dot)...].lowercased()) { return text }
            }
        }
        return ns.substring(to: match.range(at: 2).location)
    }

    /// File endings that mark a `MEDIA:` path as finished (anything shorter —
    /// `.jp` mid-stream — is still being typed).
    private static let wholeExtensions: Set<String> = imageExtensions.union(
        ["pdf", "html", "htm", "csv", "txt", "md", "json", "mp3", "m4a", "wav", "aac", "ogg", "opus",
         "flac", "mp4", "mov", "m4v", "webm", "zip", "docx", "xlsx", "pptx", "diff", "patch", "svg"])

    private static let partialPattern = try! NSRegularExpression(
        pattern: #"(^|\s)(M(?:E(?:D(?:I(?:A(?::\S*)?)?)?)?)?|!\[[^\]\n]*(?:\]\([^)\s]*)?)$"#)

    /// `![caption](/absolute/server/path)` — chat_image's show_with — through
    /// the cookie-gated media endpoint, keeping the caption.
    static func localImages(_ text: String, base: String = "") -> String {
        guard text.contains("](/") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in localImagePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let alt = ns.substring(with: match.range(at: 1))
            let path = ns.substring(with: match.range(at: 2))
            out += path.hasPrefix("/api/")
                ? ns.substring(with: match.range)
                : "![\(alt)](\(base)\(mediaSource(path)))"
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }

    private static let localImagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\((/[^)\s]+)\)"#)

    /// Width ÷ height of a saved chat image, read off its name
    /// (`…_<W>x<H>.<ext>`, agent/chat_media.py) so its tile holds the right
    /// space before the bytes arrive. Nil when the name doesn't carry it.
    static func aspect(of source: String) -> CGFloat? {
        var path = source
        if let range = source.range(of: "path=") {
            let value = source[range.upperBound...].split(separator: "&").first.map(String.init) ?? ""
            path = value.removingPercentEncoding ?? value
        }
        path = path.split(separator: "?").first.map(String.init) ?? path
        let ns = path as NSString
        guard let m = sizePattern.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
              let w = Double(ns.substring(with: m.range(at: 1))),
              let h = Double(ns.substring(with: m.range(at: 2))), w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }

    private static let sizePattern = try! NSRegularExpression(pattern: #"_(\d+)x(\d+)\.[A-Za-z0-9]+$"#)

    /// A `data:` image's bytes (nil for anything else).
    static func inlineImageData(_ source: String) -> Data? {
        guard source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    /// The cookie-gated `/api/media` URL behind a file on the server,
    /// root-relative: join it onto ``apiBase(_:)``.
    static func mediaSource(_ path: String) -> String {
        "/api/media?path=" + (path.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? path)
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

/// Fetched link metadata, so a preview scrolled away and back (or the same link
/// in two replies, or the island opened again) is fetched once. `NSCache` evicts under memory
/// pressure.
@MainActor
final class ChatLinkMetadataCache {
    static let shared = ChatLinkMetadataCache()

    private let cache: NSCache<NSURL, LPLinkMetadata> = {
        let cache = NSCache<NSURL, LPLinkMetadata>()
        cache.countLimit = 128
        return cache
    }()
    private var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]

    func cached(_ url: URL) -> LPLinkMetadata? { cache.object(forKey: url as NSURL) }

    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<LPLinkMetadata?, Never> {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            return try? await provider.startFetchingMetadata(for: url)
        }
        inFlight[url] = task
        let metadata = await task.value
        inFlight[url] = nil
        if let metadata { cache.setObject(metadata, forKey: url as NSURL) }
        return metadata
    }
}
