import Foundation

/// The chat's markdown, parsed once per distinct text: every open of the island and every token
/// of a streaming reply re-renders the turns. The blocks are the phone's own `MarkdownBlocks`
/// (compiled in from `ios_app`), so a reply reads the same on both; inline styling is left to
/// `AttributedString(markdown:)`.
enum ChatMarkdown {
    /// The reply as blocks, `MEDIA:` lines already turned into images and pages and links into
    /// their cards.
    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let blocks = MarkdownBlocks.withEmbeds(MarkdownBlocks.split(ChatMedia.rewrite(text)))
        blockCache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    /// Bold, italics, `code` and links inside one block, parsed once per text.
    static func inline(_ s: String) -> AttributedString {
        let key = s as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        inlineCache.setObject(Box(value), forKey: key)
        return value
    }

    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // NSCache is internally synchronised and evicts under memory pressure.
    nonisolated(unsafe) private static let blockCache: NSCache<NSString, Box<[MarkdownBlock]>> = {
        let cache = NSCache<NSString, Box<[MarkdownBlock]>>()
        cache.countLimit = 256
        return cache
    }()

    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 1_024
        return cache
    }()
}
