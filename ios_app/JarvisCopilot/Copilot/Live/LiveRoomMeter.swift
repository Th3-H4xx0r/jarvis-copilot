import SwiftUI

/// What the room sounds like, right now, and how much of it is being kept.
///
/// This is the Live screen's one signature element, and the only thing on it
/// that moves. An ambient recorder's real failure is not "the button is the
/// wrong shade" — it is recording a room it cannot actually hear: a muted
/// route, a phone in a bag, a mic another app took. A level needle answers
/// "does the app think it is recording". The tape below answers the question
/// that matters, "has this room been making sound for the last eight seconds",
/// because it keeps the recent past on screen instead of only the instant.
///
/// Everything here is measured. `level` comes from the peak amplitude of the
/// actual capture frames, the clock from when capture actually began, the
/// figure from the bytes the server says it is holding. Nothing animates on a
/// timer for its own sake — when the room is silent the tape is flat, and that
/// is the point.
struct LiveRoomMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize

    /// What the recorder is doing. Drives every cue below.
    let state: LiveCaptureState
    /// The state in the store's own words ("Recording on device").
    let headline: String
    /// The qualifier the store attached to it, if any, already sentence-cased.
    var detail: String? = nil
    /// The retained-audio figure, in the store's words ("2.4 MB stored").
    let kept: String
    /// Seconds since capture began, or nil when that is not known.
    var elapsed: TimeInterval? = nil
    /// The most recent input levels, oldest first, each 0...1.
    var tape: [Double] = []
    /// A lane fallback or similar notice that must be stated, not implied.
    var notice: String = ""
    /// One line instead of a card, for while a recording is simply running: the
    /// full card took a quarter of the screen from the transcript it was
    /// recording. The caller only asks for it when there is nothing to warn
    /// about, and the light, the clock and the moving tape all stay.
    var compact = false

    var body: some View {
        if compact { slim } else { full }
    }

    private var slim: some View {
        GlassCard(padding: 11, fill: fill, borderColor: border) {
            HStack(spacing: 10) {
                LiveCaptureDot(state: state)
                Text("Recording")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                    .fixedSize()
                if let elapsed {
                    Text(LiveFormat.stamp(ms: Int(elapsed * 1000)))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(JcTheme.text)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: Int(elapsed))
                        .fixedSize()
                }
                LiveRoomTape(samples: tape, live: state == .recording, reduceMotion: reduceMotion,
                             height: 18)
                    .frame(minWidth: 40)
                if let size = keptSize {
                    Text(size)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Shows the full recorder")
        .accessibilityAddTraits(.isHeader)
    }

    /// "2.4 MB stored" → "2.4 MB". Nothing before the first byte: "No audio
    /// stored yet" does not fit on the line, and the full card says it.
    private var keptSize: String? {
        let suffix = " stored"
        guard kept.hasSuffix(suffix) else { return nil }
        return String(kept.dropLast(suffix.count))
    }

    private var full: some View {
        GlassCard(padding: 15, fill: fill, borderColor: border) {
            VStack(alignment: .leading, spacing: 12) {
                header.layoutPriority(1)
                LiveRoomTape(samples: tape, live: state == .recording, reduceMotion: reduceMotion)
                footer
                if !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Header: the state, and how long it has been true

    /// The state and the clock side by side, stacked instead at accessibility
    /// text sizes so neither has to be shortened to fit (the app's convention —
    /// see `ChatDashboard`'s column collapse).
    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                stateLine
                if let elapsed { clock(elapsed) }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                stateLine
                Spacer(minLength: 8)
                if let elapsed { clock(elapsed) }
            }
        }
    }

    private var stateLine: some View {
        HStack(spacing: 9) {
            LiveCaptureDot(state: state)
            Text(headline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The house elapsed-clock recipe (`Ring/WorkoutViews`): rounded, monospaced
    /// digits, and a numeric transition so a second ticking over does not shove
    /// the layout.
    private func clock(_ seconds: TimeInterval) -> some View {
        Text(LiveFormat.stamp(ms: Int(seconds * 1000)))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(JcTheme.text)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: Int(seconds))
    }

    // MARK: - Footer: the qualifier, and the honest figure

    /// The qualifier and the retained figure are two different facts, so they get
    /// two slots rather than being joined with a "·" into one sentence that reads
    /// as though it said the same thing twice.
    @ViewBuilder
    private var footer: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                if let detail { detailText(detail) }
                keptText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let detail { detailText(detail) }
                Spacer(minLength: 6)
                keptText
            }
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(state.qualifierIsWarning ? JcTheme.amber : JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var keptText: some View {
        Text(kept)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Surface

    /// Recording changes the card's ENCLOSURE, not just a hue: a visible border
    /// appears where there was a hairline. See `LiveCaptureDot` for why the
    /// colour is never the only cue.
    private var fill: Color {
        if reduceTransparency {
            return state == .recording ? JcTheme.surface : JcTheme.surfaceAlt
        }
        return state == .recording ? JcTheme.danger.opacity(0.12) : JcTheme.glassFill
    }

    private var border: Color {
        state == .recording ? JcTheme.danger.opacity(0.40) : JcTheme.glassBorder
    }

    private var spokenLabel: String {
        var parts = [headline]
        if let elapsed {
            parts.append("for " + LiveFormat.spokenDuration(seconds: Int(elapsed)))
        }
        if let detail { parts.append(detail) }
        parts.append(kept)
        if !notice.isEmpty { parts.append(notice) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - The state, and how it is signalled

/// What the recorder is doing, as the screen needs to show it.
enum LiveCaptureState: Equatable {
    case idle
    case preparing
    case recording
    /// Capture is on but audio is not arriving — another app has the mic.
    case paused
    /// Capture stopped itself and said why.
    case stopped

    /// A qualifier on these states is a warning, not a footnote.
    var qualifierIsWarning: Bool {
        switch self {
        case .paused, .stopped: return true
        case .idle, .preparing, .recording: return false
        }
    }
}

/// The recording light.
///
/// `accessibility.md › Contrast` forbids carrying information by colour alone,
/// and this screen records OTHER PEOPLE, so "am I recording" is the one thing
/// that must never depend on telling teal from grey. Four cues stack here, and
/// hue is the last of them:
///
///   * **fill** — recording is a SOLID disc inside its ring; every other state
///     is a hollow ring. Solid versus hollow survives greyscale and every form
///     of colour blindness.
///   * **ring** — the disc sits in a ring only while recording, so the glyph
///     changes size and shape at once.
///   * **text** — the headline beside it says the state in words.
///   * **colour** — `JcTheme.danger`, deliberately NOT the accent. The accent
///     means "you can tap this" everywhere else in the app; spending it on a
///     state would make the one red thing on screen ambiguous.
///
/// The card adds two more: the clock EXISTS only while recording, and the tape
/// only moves while recording.
struct LiveCaptureDot: View {
    let state: LiveCaptureState

    private var recording: Bool { state == .recording }

    private var tint: Color {
        switch state {
        case .recording: return JcTheme.danger
        case .paused: return JcTheme.amber
        case .stopped: return JcTheme.danger
        case .preparing, .idle: return JcTheme.muted
        }
    }

    var body: some View {
        ZStack {
            if recording {
                Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1.5)
                Circle().fill(tint).frame(width: 9, height: 9)
            } else {
                Circle().strokeBorder(tint, lineWidth: 1.5).frame(width: 10, height: 10)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - The tape

/// The last few seconds of the room, oldest at the left.
///
/// Drawn rather than composed of views: at ten samples a second a `Canvas` is
/// one redraw where sixty `Capsule`s would be sixty layout passes.
///
/// Two details are information, not decoration. The bars fade toward the left,
/// so which end is NOW is visible without anything having to move. And a
/// baseline is always drawn at zero, so a dead microphone (perfectly flat) can
/// be told apart from a quiet room (a low fuzz above the line) — the single
/// most useful distinction on an ambient recorder, and one a bare level needle
/// cannot make.
struct LiveRoomTape: View {
    /// Oldest first, each 0...1.
    let samples: [Double]
    let live: Bool
    var reduceMotion: Bool = false

    /// 34 in the full card, less on the slim bar.
    var height: CGFloat = 34

    /// Bar geometry. Fixed rather than scaled with Dynamic Type: this is a
    /// graphic, and the app's type scale is deliberately fixed (`JcTheme`).
    private static let barWidth: CGFloat = 3
    private static let gap: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let slot = Self.barWidth + Self.gap
            let columns = max(Int(size.width / slot), 1)
            let floorY = size.height - 1
            // The baseline: where "no signal at all" sits, so silence and a dead
            // mic do not look the same.
            context.fill(Path(CGRect(x: 0, y: floorY, width: size.width, height: 1)),
                         with: .color(JcTheme.muted.opacity(0.35)))

            // Right-aligned: the newest sample is always hard against the right
            // edge, so a part-filled tape grows from the right instead of
            // sliding, and never implies samples it does not have.
            let shown = samples.suffix(columns)
            let firstColumn = columns - shown.count
            for (offset, sample) in shown.enumerated() {
                let column = firstColumn + offset
                let x = size.width - CGFloat(columns - column) * slot + Self.gap / 2
                let magnitude = min(max(sample, 0), 1)
                let barHeight = max(1.5, magnitude * (size.height - 3))
                // Age fades to the left. Floored well above invisible so the
                // oldest bars stay legible on black.
                let age = columns > 1 ? Double(column) / Double(columns - 1) : 1
                let opacity = 0.45 + 0.55 * age
                let rect = CGRect(x: x, y: floorY - barHeight,
                                  width: Self.barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                             with: .color(JcTheme.text.opacity(live ? opacity : 0.25)))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // Only the newest bar changes per tick, so this is a 100ms fade on one
        // column rather than a sweep. Off entirely under Reduce Motion, where
        // the samples simply appear (the caller also slows the sampling).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: samples.last ?? 0)
        // The figure it illustrates is already spoken by the card's label; a
        // waveform read aloud sample by sample is noise.
        .accessibilityHidden(true)
    }
}

// MARK: - Splitting the store's sentence

/// `LiveStore.statusText` is one honest sentence, sometimes with a qualifier
/// after an em dash ("Not recording — 2 KB still to upload"). The card wants
/// those as two things: a state to put beside the light, and a qualifier to put
/// in the footer.
///
/// Split rather than re-derived in the view on purpose. Every branch of
/// `statusText` exists because it is a state where the honest answer is not
/// "Recording"; rebuilding that logic here would quietly drop the ones the view
/// forgot about.
enum LiveRecorderStatus {
    static let separator = " — "

    static func split(_ text: String) -> (headline: String, detail: String?) {
        guard let range = text.range(of: separator) else { return (text, nil) }
        let headline = String(text[text.startIndex..<range.lowerBound])
        let tail = String(text[range.upperBound...])
        guard let first = tail.first else { return (headline, nil) }
        return (headline, first.uppercased() + tail.dropFirst())
    }
}

extension LiveFormat {
    /// A duration as VoiceOver should say it, since "12:04" is read as a time of
    /// day.
    static func spokenDuration(seconds: Int) -> String {
        let total = max(seconds, 0)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
