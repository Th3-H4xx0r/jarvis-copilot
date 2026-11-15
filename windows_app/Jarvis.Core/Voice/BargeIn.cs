namespace Jarvis.Core.Voice;

// Words-only barge-in. Ports of ios_app/JarvisCopilot/Copilot/Voice/VoiceBargeIn.swift (the detector),
// the `bargeIn*` tuning in VoiceStore.swift (the `#else`, i.e. Mac, values), and VoiceStore's words
// check (startBargeCheck / continueBargeCheck / bargeCheckCooldownQuietMs).

/// The Mac tuning.
public static class BargeInTuning
{
    /// Voiced audio has to fill this much of the last WindowMs.
    public const int SustainMs = 350;
    /// The level a frame must reach to count as voiced over the reply (before the echo lifts it).
    public const double SpeechAmp = 0.03;
    public const int WindowMs = 500;
    /// Voiced also means clearing the reply's own echo by this much.
    public const double EchoMargin = 1.5;
    /// The echo level is this high percentile of the mic over EchoWindowMs.
    public const int EchoWindowMs = 3000;
    public const double EchoPercentile = 0.9;
    /// No echo level until this much has been heard.
    public const int EchoMinMs = 300;
    /// Nothing counts this soon after playback starts (the canceller is still settling).
    public const int SettleMs = 500;
    /// A sound that clears the bar turns the reply down to this while the words check listens.
    public const float DuckVolume = 0.2f;
    /// The check listens at least this much mic audio, then gives up once the mic has been under the
    /// bar for CheckQuietMs.
    public const int CheckMinMs = 1200;
    public const int CheckQuietMs = 500;
    /// A sound that goes on this long with no words is let go.
    public const int CheckMaxMs = 4000;
}

/// The sound half of barge-in: is something louder than the reply's own echo being said over it, for
/// long enough? (Whether it is words is WordsCheck's job.)
public sealed class BargeInDetector
{
    public readonly record struct BargeFrame(int Ms, bool Voiced, double Amp);
    public readonly record struct EchoFrame(int Ms, double Amp);

    private readonly List<BargeFrame> _frames = new();
    private readonly List<EchoFrame> _echoFrames = new();

    /// The last WindowMs of mic frames under the reply.
    public IReadOnlyList<BargeFrame> Frames => _frames;
    /// Recent mic frames under the reply, for the echo level.
    public IReadOnlyList<EchoFrame> EchoFrames => _echoFrames;

    public int VoicedMs => _frames.Sum(f => f.Voiced ? f.Ms : 0);
    public bool LastVoiced => _frames.Count > 0 && _frames[^1].Voiced;

    /// What the mic hears under the reply when nobody is talking: the reply's leftover echo.
    public double EchoFloor
    {
        get
        {
            if (_echoFrames.Sum(f => f.Ms) < BargeInTuning.EchoMinMs) return 0;
            var sorted = _echoFrames.Select(f => f.Amp).OrderBy(a => a).ToList();
            return sorted[(int)((sorted.Count - 1) * BargeInTuning.EchoPercentile)];
        }
    }

    /// The level a frame has to reach to count as voiced over the reply.
    public double Bar => Math.Max(BargeInTuning.SpeechAmp, EchoFloor * BargeInTuning.EchoMargin);

    /// A frame that is the reply's echo for sure (the canceller still settling).
    public void NoteEcho(double amp, int frameMs)
    {
        _echoFrames.Add(new EchoFrame(frameMs, amp));
        var total = _echoFrames.Sum(f => f.Ms);
        while (total > BargeInTuning.EchoWindowMs && _echoFrames.Count > 1)
        {
            total -= _echoFrames[0].Ms;
            _echoFrames.RemoveAt(0);
        }
    }

    /// One mic frame under the reply; true once voiced audio fills SustainMs of the window. With
    /// `learning` off (a sound being checked or waited out) nothing moves the echo level.
    public bool Feed(double amp, int frameMs, bool learning)
    {
        var voiced = amp >= Bar;
        // A frame under the bar teaches the echo level at once. One over it waits until it leaves the
        // window: it may be the user's first words. Aged out without triggering, it was the reply.
        if (!voiced && learning) NoteEcho(amp, frameMs);
        _frames.Add(new BargeFrame(frameMs, voiced, amp));
        var total = _frames.Sum(f => f.Ms);
        while (total > BargeInTuning.WindowMs && _frames.Count > 1)
        {
            var aged = _frames[0];
            _frames.RemoveAt(0);
            total -= aged.Ms;
            if (aged.Voiced && learning) NoteEcho(aged.Amp, aged.Ms);
        }
        return VoicedMs >= BargeInTuning.SustainMs;
    }

    public void Reset()
    {
        _frames.Clear();
        _echoFrames.Clear();
    }
}

/// One words check: a sound cleared the bar, the caller turned the reply down to DuckVolume, and the
/// recogniser listens. Words that aren't the reply's own interrupt; no words after CheckMinMs plus
/// CheckQuietMs of quiet releases; CheckMaxMs with no words gives up (then run a QuietCooldown).
/// `bar` is the detector's Bar when the check opened: nothing is learned during a check, so it holds.
public sealed class WordsCheck
{
    public enum Verdict { Pending, Interrupt, Release, GiveUp }

    private readonly VoiceReply _reply;
    private readonly double _bar;
    private Verdict _decided = Verdict.Pending;

    public WordsCheck(VoiceReply reply, double bar = BargeInTuning.SpeechAmp)
    {
        _reply = reply;
        _bar = bar;
    }

    /// Mic audio since the check began, and the current run under the bar.
    public int HeardMs { get; private set; }
    public int QuietMs { get; private set; }
    /// The recogniser's latest text (the start of the new turn if it interrupts).
    public string Heard { get; private set; } = "";
    /// The words in Heard that are not the reply's.
    public IReadOnlyList<string> Words { get; private set; } = Array.Empty<string>();

    /// One mic frame (`frameMs` 0 for a recogniser update alone) and the recogniser's latest text, if
    /// it has new text. Once decided, the verdict stays.
    public Verdict Feed(double amp, int frameMs, string? recognised)
    {
        if (_decided != Verdict.Pending) return _decided;
        if (recognised != null)
        {
            Heard = recognised;
            Words = _reply.UserWords(recognised);
            if (Words.Count > 0) return _decided = Verdict.Interrupt;
        }
        if (frameMs <= 0) return Verdict.Pending;
        HeardMs += frameMs;
        QuietMs = amp >= _bar ? 0 : QuietMs + frameMs;
        if (HeardMs >= BargeInTuning.CheckMaxMs) return _decided = Verdict.GiveUp;
        if (HeardMs >= BargeInTuning.CheckMinMs && QuietMs >= BargeInTuning.CheckQuietMs) return _decided = Verdict.Release;
        return Verdict.Pending;
    }
}

/// After a check gave up on a sound that went on, none starts again until the mic has been under the
/// bar for CheckQuietMs.
public sealed class QuietCooldown
{
    private int _quietMs;

    public bool Done { get; private set; }

    /// One mic frame; true once the cooldown is over.
    public bool Feed(bool voiced, int frameMs)
    {
        if (Done) return true;
        _quietMs = voiced ? 0 : _quietMs + frameMs;
        Done = _quietMs >= BargeInTuning.CheckQuietMs;
        return Done;
    }
}
