import SwiftUI

/// Pure presentation helpers for the Voice screen — the parts of `voice_page.dart`
/// that are decisions rather than layout, kept out of the view so they can be
/// asserted directly.

/// The soft conversational prompt shown above the orb before the user has said
/// anything. Port of `_captionFor`.
func voiceCaption(for state: VoiceState) -> String {
    switch state {
    case .idle:       return "Tap the mic to start talking"
    case .connecting: return "Connecting…"
    case .listening:  return "Go ahead, I'm listening…"
    case .thinking:   return "Thinking it through…"
    case .speaking:   return "Speaking…"
    case .error:      return "Something went wrong — tap to retry"
    }
}

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

/// SF Symbol for one `deviceKinds` entry (see `deviceIconKind`). Anything
/// unrecognised falls back to the generic desktop, exactly as the kind mapper does.
func voiceDeviceSymbol(_ kind: String) -> String {
    switch kind {
    case "watch":   return "applewatch"
    case "tablet":  return "ipad"
    case "phone":   return "iphone"
    case "laptop":  return "laptopcomputer"
    case "web":     return "globe"
    case "desktop": return "desktopcomputer"
    default:        return "desktopcomputer"
    }
}

/// Nav-tab index of the Voice tab, for `orbTickerEnabled`. Derived from `AppTab`
/// rather than hard-coded so re-ordering the tabs can't silently freeze the orb.
let voiceTabIndex: Int = AppTab.allCases.firstIndex(of: .voice) ?? 1
