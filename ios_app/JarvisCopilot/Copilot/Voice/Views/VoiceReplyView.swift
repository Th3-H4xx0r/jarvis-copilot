import SwiftUI

/// The assistant's reply, rendered word-by-word: words already spoken are white,
/// the rest grey. Scrolls itself so the segment being voiced stays in view.
///
/// Port of `_KaraokeReply` in `voice_page.dart` — 22 pt / w500 / 1.4 line height /
/// −0.2 tracking, centred and unboxed. Flutter injected a zero-size marker into
/// one big paragraph and scrolled to its laid-out position; here the reply is
/// already segmented (``VoiceReply`` builds one segment per TTS clip), so each
/// segment is its own `Text` with its own id and `ScrollViewReader` follows —
/// same effect, far less geometry maths.
struct VoiceKaraokeReply: View {
    let segments: [VoiceSegment]
    /// How many leading words of the whole reply have been spoken.
    let spokenWords: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: VoiceReplyStyle.lineSpacing) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(attributed(segment))
                            .voiceReplyStyle()
                            .id(index)
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: spokenWords) { _, _ in
                let active = voiceActiveSegment(segments, spokenWords: spokenWords)
                guard active >= 0 else { return }
                withAnimation(.easeOut(duration: 0.26)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }

    /// One run per word, coloured by whether it has been voiced yet.
    private func attributed(_ segment: VoiceSegment) -> AttributedString {
        var out = AttributedString()
        for (i, word) in segment.words.enumerated() {
            var run = AttributedString(i == 0 ? word : " " + word)
            run.foregroundColor = segment.wordOffset + i < spokenWords ? JcTheme.text : JcTheme.muted
            out.append(run)
        }
        return out
    }
}

/// A reply with nothing to karaoke: the whole string lit, in the same type as
/// ``VoiceKaraokeReply``.
///
/// Flutter renders a failure THROUGH the reply slot (`reply = _c.error!` with
/// `spokenWords = 1 << 30`) rather than in a banner, so an error reads as an
/// answer rather than as chrome. `tint` is what makes that legible — the error
/// text is the reply, in the reply's own size.
struct VoicePlainReply: View {
    let text: String
    var tint: Color = JcTheme.text

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .voiceReplyStyle()
                .foregroundStyle(tint)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The reply paragraph's type, shared so the karaoke and plain forms can't drift.
enum VoiceReplyStyle {
    #if JC_MAC_VOICE
    /// The phone's 22 pt is a full-screen size: one reply fills a 6" display and
    /// reads from arm's length. The Mac panel is a menubar popover a third that
    /// tall, where the same type runs past the bottom of the reply area and
    /// collides with the transcript above it — and it is read from desk
    /// distance, where it is simply shouting.
    static let size: CGFloat = 15
    static let lineSpacing: CGFloat = 3
    #else
    static let size: CGFloat = 22
    /// Flutter's `height: 1.4` minus the system font's own line height.
    static let lineSpacing: CGFloat = 4.6
    #endif
    static let tracking: CGFloat = -0.2
}

private extension Text {
    func voiceReplyStyle() -> some View {
        self.font(.system(size: VoiceReplyStyle.size, weight: .medium))
            .kerning(VoiceReplyStyle.tracking)
            .lineSpacing(VoiceReplyStyle.lineSpacing)
            .multilineTextAlignment(.center)
    }
}
