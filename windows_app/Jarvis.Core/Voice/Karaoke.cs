using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Jarvis.Core.Voice;

// The karaoke word highlight. Ports of ios_app/JarvisCopilot/Copilot/Voice/VoiceKaraoke.swift
// (VoiceSegment, voiceWordTokens, voiceSplitForSpeech), Copilot/Shared/SpokenMarkdown.swift
// (voicePlainSpeech) and Copilot/Voice/VoiceReply.swift.

/// Text helpers. Lengths count user-perceived characters (text elements), like Swift's `String.count`.
public static class SpeechText
{
    private static readonly Regex SentenceSplit = new(@"(?<=[.!?])\s+|\n+", RegexOptions.CultureInvariant);
    private static readonly Regex Fences = new(@"```[\s\S]*?```", RegexOptions.CultureInvariant);
    private static readonly Regex Links = new(@"\[([^\]]+)\]\([^)]*\)", RegexOptions.CultureInvariant);
    private static readonly Regex InlineCode = new("`([^`]+)`", RegexOptions.CultureInvariant);
    private static readonly Regex Headings = new(@"^\s{0,3}#{1,6}\s*", RegexOptions.Multiline | RegexOptions.CultureInvariant);
    private static readonly Regex Quotes = new(@"^\s{0,3}>\s?", RegexOptions.Multiline | RegexOptions.CultureInvariant);
    private static readonly Regex Bullets = new(@"^\s{0,3}[-*+]\s+", RegexOptions.Multiline | RegexOptions.CultureInvariant);
    private static readonly Regex Emphasis = new(@"\*\*|\*|__|_|~~|`", RegexOptions.CultureInvariant);
    private static readonly Regex BlankRuns = new(@"\n{3,}", RegexOptions.CultureInvariant);

    internal static int Length(string s) => new StringInfo(s).LengthInTextElements;

    /// Whitespace-delimited tokens.
    public static IReadOnlyList<string> WordTokens(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// Split a reply into sentence/line-sized chunks for per-clip TTS and karaoke, merging fragments
    /// so there is no clip per word.
    public static IReadOnlyList<string> SplitForSpeech(string text)
    {
        var output = new List<string>();
        var buf = "";
        foreach (var part in SentenceSplit.Split(text))
        {
            var p = part.Trim();
            if (p.Length == 0) continue;
            if (buf.Length == 0) buf = p;
            else if (Length(buf) < 40) buf += " " + p;
            else
            {
                output.Add(buf);
                buf = p;
            }
        }
        if (buf.Length > 0) output.Add(buf);
        return output;
    }

    /// Strip markdown so the reply reads like clean speech (matches the server's `_speakable`).
    public static string PlainSpeech(string text)
    {
        var s = text;
        s = Fences.Replace(s, " ");
        s = Links.Replace(s, "$1");
        s = InlineCode.Replace(s, "$1");
        s = Headings.Replace(s, "");
        s = Quotes.Replace(s, "");
        s = Bullets.Replace(s, "");
        s = Emphasis.Replace(s, "");
        s = BlankRuns.Replace(s, "\n\n");
        return s.Trim();
    }
}

/// One spoken segment of the reply: a sentence-ish chunk with its own TTS clip, its word tokens and a
/// duration-proportional schedule that advances the highlight as the clip plays.
public struct VoiceSegment
{
    private double[] _starts;

    public VoiceSegment(string text, int wordOffset)
    {
        Text = text;
        WordOffset = wordOffset;
        Words = SpeechText.WordTokens(text);
        _starts = Array.Empty<double>();
        AudioAssigned = false;
        DurMs = 0;
        Complete = false;
        LocalSpoken = 0;
    }

    /// Plain (markdown-stripped) display text.
    public string Text { get; }
    /// Global index of this segment's first word.
    public int WordOffset { get; }
    public IReadOnlyList<string> Words { get; }
    /// A clip has been paired to this segment.
    public bool AudioAssigned { get; set; }
    /// This segment's clip duration (set by Schedule).
    public int DurMs { get; set; }
    /// The exact clip duration is known.
    public bool Complete { get; set; }
    /// Words spoken so far within this segment.
    public int LocalSpoken { get; set; }
    /// Per-word start time (ms) within the clip.
    public readonly IReadOnlyList<double> Starts => _starts ?? Array.Empty<double>();

    /// Spread the words across a clip of `clipMs`. Each word weighs its length plus one, plus 6 after
    /// a sentence end and 3 after a clause break.
    public void Schedule(int clipMs)
    {
        DurMs = clipMs;
        var words = Words ?? Array.Empty<string>();
        var n = words.Count;
        if (n == 0)
        {
            _starts = Array.Empty<double>();
            return;
        }
        var weights = new double[n];
        var total = 0.0;
        for (var i = 0; i < n; i++)
        {
            var w = words[i];
            var wt = SpeechText.Length(w) + 1.0;
            var last = w[^1];
            if (".!?".Contains(last)) wt += 6.0;
            else if (",;:".Contains(last)) wt += 3.0;
            weights[i] = wt;
            total += wt;
        }
        var output = new double[n];
        var cum = 0.0;
        for (var i = 0; i < n; i++)
        {
            output[i] = total > 0 ? cum / total * DurMs : 0;
            cum += weights[i];
        }
        _starts = output;
    }

    /// Move the highlight to whatever word the clip is up to at `posMs`. Never steps backward.
    public void Advance(int posMs)
    {
        var starts = Starts;
        var k = LocalSpoken;
        while (k < starts.Count && starts[k] <= posMs) k++;
        if (k > LocalSpoken) LocalSpoken = k;
    }
}

/// The assistant's reply as it streams in, plus the karaoke word highlight. Each text chunk becomes a
/// segment with its own clip; the clip's duration drives a word schedule, so the highlight re-syncs to
/// real audio at every segment boundary.
public sealed class VoiceReply
{
    /// How far either side of the playhead the reply can still be echoing.
    public const int EchoWordsBack = 40;
    public const int EchoWordsAhead = 20;
    /// What a recogniser writes for a cough, a breath or a throat-clear.
    public static readonly IReadOnlySet<string> FillerWords = new HashSet<string>
    {
        "uh", "um", "uhm", "umm", "hmm", "hm", "mm", "mhm", "ah", "oh", "eh", "er", "erm", "ha", "huh", "ugh",
    };

    private readonly List<VoiceSegment> _segments = new();
    /// ~200 wpm by default (300 ms/word), tuned by completed segments.
    private double _msPerWord = 300;

    public IReadOnlyList<VoiceSegment> Segments => _segments;
    /// The joined plain reply: what the view renders.
    public string Text { get; private set; } = "";
    /// How many leading words of Text have been spoken.
    public int SpokenWords { get; private set; }
    public int TotalWords { get; private set; }
    /// Index of the segment whose clip is playing.
    public int CurrentSegment { get; private set; } = -1;

    public bool IsEmpty => Text.Trim().Length == 0;

    /// Clear all reply and highlight state at the start of a new turn.
    public void Reset()
    {
        _msPerWord = 300;
        _segments.Clear();
        Text = "";
        SpokenWords = 0;
        TotalWords = 0;
        CurrentSegment = -1;
    }

    /// Append a chunk of reply text as a new segment (markdown-stripped). Returns the new segment's
    /// index, or null when the chunk stripped to nothing: no clip may be tagged with it then.
    public int? Append(string raw)
    {
        var plain = SpeechText.PlainSpeech(raw).Trim();
        if (plain.Length == 0) return null;
        var segment = new VoiceSegment(plain, TotalWords);
        TotalWords += segment.Words.Count;
        _segments.Add(segment);
        Text = string.Join("\n\n", _segments.Select(s => s.Text));
        return _segments.Count - 1;
    }

    public void AppendText(string chunk) => Append(chunk);

    /// Pair an incoming clip with the most recent segment that doesn't have audio yet.
    public int? ClaimSegmentTag()
    {
        for (var i = _segments.Count - 1; i >= 0; i--)
        {
            if (_segments[i].AudioAssigned) continue;
            var s = _segments[i];
            s.AudioAssigned = true;
            _segments[i] = s;
            return i;
        }
        return null;
    }

    /// Mark `index` as having a clip.
    public void AssignAudio(int index)
    {
        if (index < 0 || index >= _segments.Count) return;
        var s = _segments[index];
        s.AudioAssigned = true;
        _segments[index] = s;
    }

    /// A segment's clip began (or its duration was corrected): schedule its words across the clip and
    /// mark everything before it spoken. A repeat call for the same segment keeps its progress.
    /// `complete: false` means `clipMs` is only the audio received so far: a lower bound, so the
    /// schedule spans max(received, speaking-rate estimate) until the exact duration is known.
    public void ClipStarted(int? segmentIndex, int clipMs, bool complete = true)
    {
        if (segmentIndex is not { } tag || tag < 0 || tag >= _segments.Count) return;
        for (var i = 0; i < tag; i++)
        {
            var before = _segments[i];
            before.LocalSpoken = before.Words.Count;
            _segments[i] = before;
        }
        var isNew = tag != CurrentSegment;
        CurrentSegment = tag;
        var s = _segments[tag];
        var estimate = EstimatedMs(s);
        var ms = clipMs;
        if (complete)
        {
            if (ms <= 0) ms = estimate;
            else if (s.Words.Count > 0)
            {
                // Learn this voice's pace, clamped so one odd clip can't wreck it.
                var observed = (double)ms / s.Words.Count;
                _msPerWord = Math.Min(700, Math.Max(180, _msPerWord * 0.5 + observed * 0.5));
            }
            s.Complete = true;
        }
        else if (!s.Complete)
        {
            ms = Math.Max(ms, estimate);
        }
        else
        {
            // A running total after the exact duration was already known: keep the exact schedule.
            ms = s.DurMs;
        }
        s.Schedule(ms);
        if (isNew) s.LocalSpoken = 0;
        _segments[tag] = s;
        RecomputeSpoken();
    }

    private int EstimatedMs(VoiceSegment s) => (int)Math.Round(s.Words.Count * _msPerWord, MidpointRounding.AwayFromZero);

    /// Advance the highlight to the current clip's playback position.
    public void ClipPosition(int? segmentIndex, int positionMs)
    {
        if (segmentIndex is not { } tag || tag != CurrentSegment || tag < 0 || tag >= _segments.Count) return;
        // A stale position from the outgoing clip would jump this segment to its last word.
        if (positionMs > _segments[tag].DurMs + 300) return;
        var s = _segments[tag];
        s.Advance(positionMs);
        _segments[tag] = s;
        RecomputeSpoken();
    }

    /// The playing clip's position.
    public void Position(int posMs) => ClipPosition(CurrentSegment, posMs);

    /// The words the user has heard so far, in order: what an interrupt tells the server was said.
    public string HeardText()
    {
        var remaining = SpokenWords;
        var words = new List<string>();
        foreach (var segment in _segments)
        {
            if (remaining <= 0) break;
            var take = Math.Min(remaining, segment.Words.Count);
            words.AddRange(segment.Words.Take(take));
            remaining -= take;
        }
        return string.Join(" ", words);
    }

    /// Reply finished: light up any words the position stream didn't reach.
    public void FinalizeSpoken() => SpokenWords = TotalWords;

    /// For tests: pretend the highlight has reached `words`.
    internal void ForceSpoken(int words) => SpokenWords = Math.Clamp(words, 0, TotalWords);

    /// The words in `heard` that are not the reply's own (its echo near the playhead), fillers and
    /// single letters left out.
    public IReadOnlyList<string> UserWords(string heard)
    {
        var all = _segments.SelectMany(s => s.Words).ToList();
        var from = Math.Max(0, SpokenWords - EchoWordsBack);
        var to = Math.Min(all.Count, SpokenWords + EchoWordsAhead);
        var echo = from < to
            ? new HashSet<string>(all.Skip(from).Take(to - from).SelectMany(PlainWords))
            : new HashSet<string>();
        return PlainWords(heard)
            .Where(w => SpeechText.Length(w) > 1 && !FillerWords.Contains(w) && !echo.Contains(w))
            .ToList();
    }

    /// Lower-cased words with punctuation dropped ("Houston," → "houston", "mm-hmm" → "mm", "hmm",
    /// "don't" → "dont").
    public static IReadOnlyList<string> PlainWords(string text)
    {
        var s = text.ToLowerInvariant().Replace("'", "").Replace("’", "");
        var output = new List<string>();
        var current = new StringBuilder();
        foreach (var rune in s.EnumerateRunes())
        {
            if (IsAlphanumeric(rune)) current.Append(rune.ToString());
            else if (current.Length > 0)
            {
                output.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0) output.Add(current.ToString());
        return output;
    }

    /// Foundation's `CharacterSet.alphanumerics`: letters, marks and numbers.
    private static bool IsAlphanumeric(Rune r) => Rune.GetUnicodeCategory(r) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };

    private void RecomputeSpoken()
    {
        var n = 0;
        for (var i = 0; i < _segments.Count; i++)
        {
            if (i < CurrentSegment) n += _segments[i].Words.Count;
            else if (i == CurrentSegment)
            {
                n += _segments[i].LocalSpoken;
                break;
            }
            else break;
        }
        SpokenWords = n;
    }
}
