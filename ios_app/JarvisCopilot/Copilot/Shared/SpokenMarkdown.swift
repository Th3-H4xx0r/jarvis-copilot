import Foundation

// Shared by the phone and the Apple Watch (compiled into BOTH targets), so the
// two surfaces strip markdown identically. It was already the rule for what the
// phone SPEAKS; the watch needs it for what it SHOWS, because raw "**bold**"
// and "- " bullets were being displayed literally.

/// Strip markdown so the reply reads like clean speech — matches what the server
/// synthesizes (see voice.py `_speakable`). Kept next to `VoiceSegment` (not in
/// the view) so the displayed text and the word schedule tokenize identically.
/// Port of `voice_controller.dart`'s `_plainSpeech`.
func voicePlainSpeech(_ text: String) -> String {
    var s = text
    s = jcRegexReplace(s, #"```[\s\S]*?```"#, " ")
    s = jcRegexReplace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
    s = jcRegexReplace(s, "`([^`]+)`", "$1")
    s = jcRegexReplace(s, #"^\s{0,3}#{1,6}\s*"#, "", .anchorsMatchLines)
    s = jcRegexReplace(s, #"^\s{0,3}>\s?"#, "", .anchorsMatchLines)
    s = jcRegexReplace(s, #"^\s{0,3}[-*+]\s+"#, "", .anchorsMatchLines)
    s = jcRegexReplace(s, #"\*\*|\*|__|_|~~|`"#, "")
    s = jcRegexReplace(s, #"\n{3,}"#, "\n\n")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}


func jcRegexReplace(_ s: String, _ pattern: String, _ template: String,
                          _ options: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
    let ns = s as NSString
    return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                       withTemplate: template)
}

