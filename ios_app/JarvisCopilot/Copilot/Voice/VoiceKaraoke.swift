import Foundation

/// One spoken segment of the reply — a sentence-ish chunk that has its own TTS
/// clip. Owns its word tokens and a duration-proportional schedule used to
/// advance the karaoke highlight as the clip plays. Because the schedule is
/// rebuilt from each clip's measured duration, the highlight re-syncs to real
/// audio at every segment boundary (drift can't accumulate).
/// Port of `voice_controller.dart`'s `_Seg`.
struct VoiceSegment: Equatable {
    /// Plain (markdown-stripped) display text.
    let text: String
    /// Global index of this segment's first word.
    let wordOffset: Int
    /// Whitespace-delimited tokens.
    let words: [String]
    /// A clip has been paired to this segment.
    var audioAssigned = false
    /// This segment's clip duration (set by `schedule`).
    var durMs = 0
    /// Per-word start time (ms) within the clip.
    private(set) var starts: [Double] = []
    /// Words spoken so far within this segment.
    var localSpoken = 0

    init(_ text: String, wordOffset: Int) {
        self.text = text
        self.wordOffset = wordOffset
        self.words = voiceWordTokens(text)
    }

    /// Spread `words` across a clip of `clipMs`. Each word's weight = its length
    /// plus extra for trailing punctuation (a natural pause), so longer words
    /// and clause/sentence breaks take proportionally more time.
    mutating func schedule(_ clipMs: Int) {
        durMs = clipMs
        let n = words.count
        if n == 0 {
            starts = []
            return
        }
        var weights = [Double](repeating: 0, count: n)
        var total = 0.0
        for i in 0..<n {
            let w = words[i]
            var wt = Double(w.count) + 1.0
            if let last = w.last {
                if ".!?".contains(last) {
                    wt += 6.0 // sentence end → long pause
                } else if ",;:".contains(last) {
                    wt += 3.0 // clause break → short pause
                }
            }
            weights[i] = wt
            total += wt
        }
        var out = [Double](repeating: 0, count: n)
        var cum = 0.0
        for i in 0..<n {
            out[i] = total > 0 ? (cum / total) * Double(durMs) : 0
            cum += weights[i]
        }
        starts = out
    }

    /// Move the highlight forward to whatever word the clip is up to at `posMs`.
    /// Monotonic — it never steps backward on a jittery position report.
    mutating func advance(_ posMs: Int) {
        var k = localSpoken
        while k < starts.count, starts[k] <= Double(posMs) { k += 1 }
        if k > localSpoken { localSpoken = k }
    }
}

/// Whitespace-delimited tokens (Dart's `RegExp(r'\S+')`).
func voiceWordTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

/// Strip markdown so the reply reads like clean speech — matches what the server
/// synthesizes (see voice.py `_speakable`). Kept next to `VoiceSegment` (not in
/// the view) so the displayed text and the word schedule tokenize identically.
/// Port of `voice_controller.dart`'s `_plainSpeech`.
func voicePlainSpeech(_ text: String) -> String {
    var s = text
    s = regexReplace(s, #"```[\s\S]*?```"#, " ")
    s = regexReplace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
    s = regexReplace(s, "`([^`]+)`", "$1")
    s = regexReplace(s, #"^\s{0,3}#{1,6}\s*"#, "", .anchorsMatchLines)
    s = regexReplace(s, #"^\s{0,3}>\s?"#, "", .anchorsMatchLines)
    s = regexReplace(s, #"^\s{0,3}[-*+]\s+"#, "", .anchorsMatchLines)
    s = regexReplace(s, #"\*\*|\*|__|_|~~|`"#, "")
    s = regexReplace(s, #"\n{3,}"#, "\n\n")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Split a reply into sentence/line-sized chunks for per-clip TTS + karaoke,
/// merging very short fragments so we don't make a clip per word.
/// Port of `voice_controller.dart`'s `_splitForSpeech`.
func voiceSplitForSpeech(_ text: String) -> [String] {
    let parts = regexSplit(text, #"(?<=[.!?])\s+|\n+"#)
    var out: [String] = []
    var buf = ""
    for part in parts {
        let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { continue }
        if buf.isEmpty {
            buf = p
        } else if buf.count < 40 {
            buf += " " + p
        } else {
            out.append(buf)
            buf = p
        }
    }
    if !buf.isEmpty { out.append(buf) }
    return out
}

// MARK: - Regex helpers
// NSRegularExpression rather than Swift Regex: the iOS 17 deployment target
// allows either, but `(?<=…)` lookbehind and `.anchorsMatchLines` translate
// 1:1 from the Dart patterns, so parity is verifiable by eye.

private func regexReplace(_ s: String, _ pattern: String, _ template: String,
                          _ options: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
    let ns = s as NSString
    return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                       withTemplate: template)
}

private func regexSplit(_ s: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [s] }
    let ns = s as NSString
    var out: [String] = []
    var last = 0
    re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let m = match else { return }
        out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
        last = m.range.location + m.range.length
    }
    out.append(ns.substring(from: last))
    return out
}
