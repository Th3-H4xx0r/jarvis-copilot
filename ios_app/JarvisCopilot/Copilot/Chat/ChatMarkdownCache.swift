import Foundation
import SwiftUI

/// Parse-once cache for the streaming markdown renderer.
///
/// `ChatMarkdownText` is a pure function of its text, which is what makes it
/// correct mid-stream — but SwiftUI re-evaluates that `body` for every token, and
/// the naive version re-ran `MarkdownBlocks.split` plus one
/// `AttributedString(markdown:)` per block each time. On a long reply that is
/// quadratic work for a linear amount of text (swift-correctness H7).
///
/// The text itself is the key, so the cache stays correct by construction: the
/// same string always renders the same way, and a growing reply simply misses
/// once per token instead of re-parsing everything above it. `NSCache` evicts
/// under memory pressure, so nothing here can grow without bound.
enum ChatMarkdownCache {

    /// Roughly a screenful of long replies plus their blocks.
    static let blockLimit = 256
    static let inlineLimit = 1_024

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    // NSCache is internally synchronised; the `unsafe` is only about Swift not
    // knowing that.
    nonisolated(unsafe) private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = blockLimit
        return cache
    }()

    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, InlineBox> = {
        let cache = NSCache<NSString, InlineBox>()
        cache.countLimit = inlineLimit
        return cache
    }()

    /// The block split of `text`, parsed at most once per distinct string.
    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlocks.split(text)
        blockCache.setObject(BlocksBox(blocks), forKey: key)
        return blocks
    }

    /// The inline-styled form of one block's text, parsed at most once.
    static func inline(for text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let value = parseInline(text)
        inlineCache.setObject(InlineBox(value), forKey: key)
        return value
    }

    /// Whether `text` has already been split — for the tests, which cannot see a
    /// saved parse any other way.
    static func hasBlocks(for text: String) -> Bool {
        blockCache.object(forKey: text as NSString) != nil
    }

    static func hasInline(for text: String) -> Bool {
        inlineCache.object(forKey: text as NSString) != nil
    }

    static func removeAll() {
        blockCache.removeAllObjects()
        inlineCache.removeAllObjects()
    }

    /// Inline markdown (bold, italics, links, `code`) the way the web UI shows it.
    /// Whitespace is preserved so a soft-wrapped reply keeps its shape, and a
    /// half-written emphasis run mid-stream falls back to plain text instead of
    /// throwing the whole block away.
    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
        }
        return attributed
    }
}
