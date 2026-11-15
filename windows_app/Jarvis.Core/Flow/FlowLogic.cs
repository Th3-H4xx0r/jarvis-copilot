using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Jarvis.Core.Flow;

/// The key logic of Flow dictation (port of the Mac's FlowKeyLogic):
/// hold the key and Jarvis listens, let go and the words are pasted; two quick taps is
/// hands-free until the next tap; Esc, or another key while held (a shortcut), cancels.
public struct FlowKeyLogic
{
    public enum Action { None, Start, Lock, Finish, Cancel, Restart }
    public enum PhaseKind { Idle, Holding, TapWait, Locked }

    public const double HoldThreshold = 0.30;
    public const double DoubleTapWindow = 0.40;

    private double _at;

    public PhaseKind Phase { get; private set; }
    /// Holding: when the key went down. TapWait: until when a second tap counts.
    public double PhaseTime => _at;
    public bool IsActive => Phase != PhaseKind.Idle;

    public Action KeyDown(double t)
    {
        switch (Phase)
        {
            case PhaseKind.Idle:
                Phase = PhaseKind.Holding; _at = t;
                return Action.Start;
            case PhaseKind.Holding:
                return Action.None;
            case PhaseKind.TapWait:
                if (t <= _at) { Phase = PhaseKind.Locked; return Action.Lock; }
                Phase = PhaseKind.Holding; _at = t;
                return Action.Restart;
            default:
                Phase = PhaseKind.Idle;
                return Action.Finish;
        }
    }

    public Action KeyUp(double t)
    {
        if (Phase != PhaseKind.Holding) return Action.None;
        if (t - _at >= HoldThreshold) { Phase = PhaseKind.Idle; return Action.Finish; }
        Phase = PhaseKind.TapWait;
        _at = t + DoubleTapWindow;
        return Action.None;
    }

    public Action OtherKey()
    {
        if (Phase is PhaseKind.Holding or PhaseKind.TapWait) { Phase = PhaseKind.Idle; return Action.Cancel; }
        return Action.None;
    }

    public Action Escape()
    {
        if (Phase == PhaseKind.Idle) return Action.None;
        Phase = PhaseKind.Idle;
        return Action.Cancel;
    }

    public Action Tick(double t)
    {
        if (Phase != PhaseKind.TapWait || t <= _at) return Action.None;
        Phase = PhaseKind.Idle;
        return Action.Cancel;
    }

    public void Lock() => Phase = PhaseKind.Locked;
    public void Reset() => Phase = PhaseKind.Idle;
}

public enum FlowStyle { verbatim, natural, polished }

public sealed record FlowReplacement(string From, string To);
public sealed record FlowSnippet(string Trigger, string Text);
public sealed record FlowAppStyle(string Exe, FlowStyle Style)
{
    /// Windows' versions of the Mac defaults: mail polished, chat and code natural.
    public static readonly IReadOnlyList<FlowAppStyle> Defaults = new[]
    {
        new FlowAppStyle("OUTLOOK.EXE", FlowStyle.polished), new FlowAppStyle("olk.exe", FlowStyle.polished),
        new FlowAppStyle("slack.exe", FlowStyle.natural), new FlowAppStyle("WhatsApp.exe", FlowStyle.natural),
        new FlowAppStyle("Claude.exe", FlowStyle.natural), new FlowAppStyle("WindowsTerminal.exe", FlowStyle.natural),
        new FlowAppStyle("Code.exe", FlowStyle.natural), new FlowAppStyle("Cursor.exe", FlowStyle.natural),
    };

    public static FlowStyle Resolve(string? exe, IReadOnlyList<FlowAppStyle> styles, FlowStyle fallback) =>
        exe == null ? fallback
        : styles.FirstOrDefault(s => string.Equals(s.Exe, exe, StringComparison.OrdinalIgnoreCase))?.Style ?? fallback;
}

public sealed class FlowDayStats { public int Words { get; set; } public double Seconds { get; set; } public int Dictations { get; set; } }

public sealed class FlowStats
{
    public Dictionary<string, FlowDayStats> Days { get; set; } = new();
    public Dictionary<string, int> Apps { get; set; } = new();

    public void Add(int words, double seconds, string? app, string day)
    {
        if (words <= 0) return;
        if (!Days.TryGetValue(day, out var d)) Days[day] = d = new FlowDayStats();
        d.Words += words;
        d.Seconds += seconds;
        d.Dictations++;
        if (!string.IsNullOrEmpty(app)) Apps[app] = Apps.GetValueOrDefault(app) + words;
    }

    public int TotalWords => Days.Values.Sum(d => d.Words);
}

/// What Flow does to the words before pasting (port of FlowText.swift).
public static class FlowText
{
    public sealed record Prepared(string Text, IReadOnlyDictionary<string, string> Snippets);

    public static Prepared Prepare(string text, IReadOnlyList<string> words, IReadOnlyList<FlowReplacement> replacements, IReadOnlyList<FlowSnippet> snippets)
    {
        var o = text;
        var marks = new Dictionary<string, string>();
        // A snippet is the whole dictation or nothing.
        for (var i = 0; i < snippets.Count; i++)
        {
            var s = snippets[i];
            if (s.Text.Length == 0 || !IsWhole(s.Trigger, o)) continue;
            var mark = $"⟦{i + 1}⟧";
            marks[mark] = s.Text;
            o = mark;
            break;
        }
        foreach (var r in replacements.Where(r => r.To.Length > 0)) o = Replacing(r.From, r.To, o);
        foreach (var w in words.Where(IsPlainWord)) o = Replacing(w, w, o);
        return new Prepared(o, marks);
    }

    public static string Finish(string text, IReadOnlyDictionary<string, string> snippets) =>
        snippets.Aggregate(text, (t, kv) => t.Replace(kv.Key, kv.Value, StringComparison.Ordinal));

    public static bool KeepsMarks(string text, IReadOnlyDictionary<string, string> snippets) => snippets.Keys.All(text.Contains);

    public static string Apply(string text, IReadOnlyList<string> words, IReadOnlyList<FlowReplacement> replacements, IReadOnlyList<FlowSnippet> snippets)
    {
        var p = Prepare(text, words, replacements, snippets);
        return Finish(p.Text, p.Snippets);
    }

    /// Every occurrence of `phrase`, any case, any separator between its words, whole words only.
    public static string Replacing(string phrase, string with, string text) =>
        Pattern(phrase) is { } re ? re.Replace(text, _ => with) : text;

    public static bool IsWhole(string phrase, string text)
    {
        var said = Tokens(text);
        var trigger = Tokens(phrase);
        return trigger.Count > 0 && said.Select(s => s.ToLowerInvariant()).SequenceEqual(trigger.Select(s => s.ToLowerInvariant()));
    }

    private static Regex? Pattern(string phrase)
    {
        var parts = Tokens(phrase);
        if (parts.Count == 0) return null;
        var body = string.Join(@"[^\p{L}\p{N}]+", parts.Select(Regex.Escape));
        return new Regex(@"(?<![\p{L}\p{N}])" + body + @"(?![\p{L}\p{N}])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    public static bool IsPlainWord(string word)
    {
        var letters = word.Count(char.IsLetterOrDigit);
        return letters >= 2 && word.All(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '\'' or '’');
    }

    public static IReadOnlyList<string> Tokens(string s)
    {
        var o = new List<string>();
        var cur = new StringBuilder();
        foreach (var ch in s)
        {
            if (char.IsLetterOrDigit(ch)) cur.Append(ch);
            else if (cur.Length > 0) { o.Add(cur.ToString()); cur.Clear(); }
        }
        if (cur.Length > 0) o.Add(cur.ToString());
        return o;
    }

    public static int WordCount(string s) =>
        s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(w => w.Any(char.IsLetterOrDigit));

    public const double TypingWordsPerMinute = 45.0;

    public static int WordsPerMinute(int words, double seconds) =>
        seconds < 1 || words <= 0 ? 0 : (int)Math.Round(words / (seconds / 60), MidpointRounding.AwayFromZero);

    public static double MinutesSaved(int words, double seconds) => Math.Max(0, words / TypingWordsPerMinute - seconds / 60);

    public static string DayKey(DateTimeOffset d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}

/// Flow's optional clean-up through `/api/flow/cleanup` (port of FlowCleanup.swift).
public static class FlowCleanup
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(12);

    public static bool WorthCleaning(string text, FlowStyle style, bool enabled) =>
        enabled && style != FlowStyle.verbatim && FlowText.WordCount(text) >= 3;

    public static bool Plausible(string cleaned, string from)
    {
        double before = FlowText.WordCount(from), after = FlowText.WordCount(cleaned);
        return after > 0 && after <= before * 1.4 + 4 && after >= before * 0.35;
    }

    public static JsonObject Body(string text, FlowStyle style, string? app, IReadOnlyList<string> words, string? model, string? provider)
    {
        var b = new JsonObject
        {
            ["text"] = text, ["style"] = style.ToString(), ["app"] = app ?? "",
            ["words"] = new JsonArray(words.Take(200).Select(w => (JsonNode?)JsonValue.Create(w)).ToArray()),
        };
        if (!string.IsNullOrEmpty(model))
        {
            b["model"] = model;
            b["provider"] = provider ?? "";
        }
        return b;
    }
}

public static class Wav
{
    public static byte[] Pcm16Mono(ReadOnlySpan<short> s, int rate)
    {
        var data = s.Length * 2;
        var o = new byte[44 + data];
        void Str(int at, string v) => Encoding.ASCII.GetBytes(v).CopyTo(o, at);
        void I32(int at, int v) => BitConverter.GetBytes(v).CopyTo(o, at);
        void I16(int at, short v) => BitConverter.GetBytes(v).CopyTo(o, at);
        Str(0, "RIFF"); I32(4, 36 + data); Str(8, "WAVE");
        Str(12, "fmt "); I32(16, 16); I16(20, 1); I16(22, 1); I32(24, rate); I32(28, rate * 2); I16(32, 2); I16(34, 16);
        Str(36, "data"); I32(40, data);
        for (var i = 0; i < s.Length; i++) BitConverter.GetBytes(s[i]).CopyTo(o, 44 + i * 2);
        return o;
    }
}
