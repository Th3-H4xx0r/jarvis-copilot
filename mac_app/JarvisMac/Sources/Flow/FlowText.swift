import Foundation

/// A word Jarvis writes another way: "cloud code" → "Claude Code".
struct FlowReplacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var from: String
    var to: String
}

/// Say the trigger, get the whole text: "my signature" → "Best,\nPranav".
struct FlowSnippet: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var trigger: String
    var text: String
}

/// What Flow does to the words before pasting them, and the numbers of the Stats
/// page. No AppKit here: it runs in the tests as it is (Tests/FlowTests.swift).
/// After coucou's FlowText (github.com/Louis-CFM/coucou, MIT).
enum FlowText {
    /// A dictation ready to paste, its snippets still set aside: each trigger heard
    /// became a mark (⟦1⟧) so nothing else (replacements, dictionary, the clean-up)
    /// touches the snippet's own text; `finish` puts the texts in at the very end.
    struct Prepared: Equatable, Sendable {
        var text: String
        var snippets: [String: String]
    }

    static func prepare(_ text: String, words: [String], replacements: [FlowReplacement],
                        snippets: [FlowSnippet]) -> Prepared {
        var out = text
        var marks: [String: String] = [:]
        for (index, snippet) in snippets.enumerated() where !snippet.text.isEmpty {
            let mark = "⟦\(index + 1)⟧"
            let replaced = replacing(snippet.trigger, with: mark, in: out)
            if replaced != out {
                marks[mark] = snippet.text
                out = replaced
            }
        }
        for replacement in replacements where !replacement.to.isEmpty {
            out = replacing(replacement.from, with: replacement.to, in: out)
        }
        for word in words where isPlainWord(word) {
            out = replacing(word, with: word, in: out)
        }
        return Prepared(text: out, snippets: marks)
    }

    static func finish(_ text: String, snippets: [String: String]) -> String {
        snippets.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// Whether a rewritten text still has every mark (otherwise the rewrite is not used).
    static func keepsMarks(_ text: String, _ snippets: [String: String]) -> Bool {
        snippets.keys.allSatisfy { text.contains($0) }
    }

    static func apply(_ text: String, words: [String], replacements: [FlowReplacement],
                      snippets: [FlowSnippet]) -> String {
        let prepared = prepare(text, words: words, replacements: replacements, snippets: snippets)
        return finish(prepared.text, snippets: prepared.snippets)
    }

    /// Every occurrence of `phrase`, ignoring case and what separates its words
    /// ("cloud code", "Cloud-Code"), but only as whole words: "art" never matches in "depart".
    static func replacing(_ phrase: String, with replacement: String, in text: String) -> String {
        guard let regex = pattern(for: phrase) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func contains(_ phrase: String, in text: String) -> Bool {
        guard let regex = pattern(for: phrase) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func pattern(for phrase: String) -> NSRegularExpression? {
        let parts = tokens(phrase)
        guard !parts.isEmpty else { return nil }
        let body = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^\\p{L}\\p{N}]+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])",
                                        options: [.caseInsensitive])
    }

    /// Only words of letters, digits, spaces, hyphens and apostrophes get their
    /// spelling fixed: "C++" would match every lone "c".
    static func isPlainWord(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter || $0.isNumber }.count
        return letters >= 2 && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    /// The letters-and-digits runs of a phrase: "Cloud-Code !" → ["Cloud", "Code"].
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Words as you would count them: "it's" is one word, a lone "?" none.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    // MARK: numbers

    /// Typing speed used to tell how much time dictating saved.
    static let typingWordsPerMinute = 45.0

    static func wordsPerMinute(words: Int, seconds: Double) -> Int {
        guard seconds >= 1, words > 0 else { return 0 }
        return Int((Double(words) / (seconds / 60)).rounded())
    }

    /// Minutes saved: what typing the words would have taken, less the time spent saying them.
    static func minutesSaved(words: Int, seconds: Double) -> Double {
        max(0, Double(words) / typingWordsPerMinute - seconds / 60)
    }

    /// Days in a row with a dictation, ending today (or yesterday, while today has none yet).
    static func streak(days: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if !days.contains(dayKey(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(dayKey(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// "2026-10-14", in the user's time zone.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 36 800 → "36.8K": short numbers for the stat cards.
    static func shortCount(_ n: Int) -> String {
        guard n >= 10_000 else { return "\(n)" }
        let thousands = Double(n) / 1000
        if thousands >= 100 { return "\(Int(thousands.rounded()))K" }
        let tenth = (thousands * 10).rounded() / 10
        return tenth == tenth.rounded() ? "\(Int(tenth))K" : String(format: "%.1fK", tenth)
    }
}
