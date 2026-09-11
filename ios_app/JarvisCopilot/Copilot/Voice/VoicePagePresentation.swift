import SwiftUI

/// Pure presentation helpers for the Voice screen — the parts of `voice_page.dart`
/// that are decisions rather than layout, kept out of the view so they can be
/// asserted directly.

/// Colour for the state pill / state label. Port of `_stateColor`.
func voiceStateColor(_ state: VoiceState) -> Color {
    switch state {
    case .listening:            return JcTheme.cyan
    case .thinking, .connecting: return JcTheme.accent
    case .speaking:             return JcTheme.accentAlt
    case .error:                return JcTheme.danger
    case .idle:                 return JcTheme.muted
    }
}

/// Which reply segment the karaoke highlight is inside, so the reply can scroll
/// itself to keep the spoken line in view.
///
/// Returns the LAST segment whose first word has been reached — matching
/// `VoiceReply.recomputeSpoken`, which counts whole segments before the current
/// one. -1 when nothing has been spoken yet.
func voiceActiveSegment(_ segments: [VoiceSegment], spokenWords: Int) -> Int {
    guard spokenWords > 0 else { return segments.isEmpty ? -1 : 0 }
    var active = -1
    for (index, segment) in segments.enumerated() where segment.wordOffset < spokenWords {
        active = index
    }
    return active
}
