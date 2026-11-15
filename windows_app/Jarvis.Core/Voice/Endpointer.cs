namespace Jarvis.Core.Voice;

public enum EndpointEvent
{
    /// Keep listening.
    None,
    /// The user has stopped talking: end the turn now.
    EndOfTurn,
}

/// Adaptive end-of-speech detection for the realtime voice turn. A 1:1 port of
/// ios_app/JarvisCopilot/Copilot/Voice/Endpointer.swift (the same constants on every platform).
///
/// Pure: the caller feeds (peak amplitude, frame duration) pairs and acts on the returned event.
///  * energy VAD with hysteresis: a high threshold opens the turn, a lower one closes it
///  * base silence ends a normal utterance, extended when the speaker is probably mid-thought
///    (a rising tail, or a very short utterance so far)
///  * under `MinUtteranceMs` of voiced audio is a blip, discarded, never endpointed
///  * a pause also counts when far below the turn's peak, or flat and steady (a car's noise)
///  * 30 s hard cap
public sealed class Endpointer
{
    // All amplitudes are normalized peaks 0..1, all durations milliseconds.

    /// Opens a turn.
    public const double SpeechThreshold = 0.012;
    /// Closes a turn; lower than SpeechThreshold (the hysteresis band).
    public const double SilenceThreshold = 0.006;
    /// Normal end-of-speech wait.
    public const int BaseSilenceMs = 650;
    /// The wait when the speaker looks mid-thought.
    public const int ExtendedSilenceMs = 1100;
    /// Less voiced audio than this gets the extended window.
    public const int ShortUtteranceMs = 1200;
    /// Less voiced audio than this is not speech at all.
    public const int MinUtteranceMs = 250;
    /// Hard cap on one utterance.
    public const int MaxUtteranceMs = 30000;
    /// Window of voiced audio compared with the one before it for a rising tail.
    public const int TailWindowMs = 150;
    public const double RisingTailRatio = 1.15;
    /// A pause also counts as silence this far below the turn's peak, capped.
    public const double RelativeSilenceRatio = 0.15;
    public const double RelativeSilenceCap = 0.06;
    /// A steady pause: every frame of the last ExtendedSilenceMs under this share of the peak, and the
    /// loudest within SteadyBandRatio of the quietest.
    public const double SteadyPeakRatio = 0.35;
    public const double SteadyBandRatio = 3.0;

    private readonly record struct Frame(int Ms, double Amp);

    private double _smoothed;
    private bool _risingTail;
    /// Recent voiced frames, newest last, bounded to two tail windows.
    private readonly List<Frame> _tail = new();
    /// The turn's last ExtendedSilenceMs of frames, voiced or not.
    private readonly List<Frame> _recent = new();

    /// The turn's loudest smoothed level.
    public double UtterancePeak { get; private set; }
    /// True while a turn is open.
    public bool Speaking { get; private set; }
    /// Milliseconds since the turn opened, including the trailing silence.
    public int SpeechMs { get; private set; }
    /// Milliseconds of contiguous silence at the tail (0 while voiced).
    public int SilenceMs { get; private set; }

    /// Below this is silence: the fixed floor, or far below this turn's peak.
    public double SilenceLevel => Math.Max(SilenceThreshold, Math.Min(UtterancePeak * RelativeSilenceRatio, RelativeSilenceCap));

    /// Milliseconds of actual voiced audio in this turn.
    public int VoicedMs => SpeechMs - SilenceMs;

    /// How much trailing silence must accumulate before this turn ends.
    public int RequiredSilenceMs
    {
        get
        {
            var rising = SilenceMs > 0 ? _risingTail : ComputeRisingTail();
            return rising || VoicedMs < ShortUtteranceMs ? ExtendedSilenceMs : BaseSilenceMs;
        }
    }

    /// Feed one mic frame: its normalized peak amplitude and its duration (from the audio, not a clock).
    public EndpointEvent Update(double amp, int dtMs)
    {
        if (dtMs <= 0) return EndpointEvent.None;

        if (!Speaking)
        {
            if (amp > SpeechThreshold)
            {
                Speaking = true;
                SpeechMs = dtMs;
                SilenceMs = 0;
                _risingTail = false;
                _tail.Clear();
                _tail.Add(new Frame(dtMs, amp));
                _smoothed = amp;
                UtterancePeak = amp;
            }
            return EndpointEvent.None;
        }

        SpeechMs += dtMs;
        _smoothed = _smoothed * 0.7 + amp * 0.3;
        UtterancePeak = Math.Max(UtterancePeak, _smoothed);
        PushRecent(dtMs, amp);

        if (amp < SilenceLevel)
        {
            // Latch the rising-tail verdict at the moment silence starts.
            if (SilenceMs == 0) _risingTail = ComputeRisingTail();
            SilenceMs += dtMs;

            if (VoicedMs < MinUtteranceMs)
            {
                // A blip: discard it once the longest window has passed.
                if (SilenceMs >= ExtendedSilenceMs) Reset();
                return EndpointEvent.None;
            }
            if (SilenceMs >= RequiredSilenceMs) return EndpointEvent.EndOfTurn;
        }
        else
        {
            SilenceMs = 0;
            _risingTail = false;
            PushTail(dtMs, amp);
        }

        if (VoicedMs >= MinUtteranceMs && SteadyPause) return EndpointEvent.EndOfTurn;
        // Last, so a max-length turn still ends while the mic is loud.
        if (SpeechMs >= MaxUtteranceMs) return EndpointEvent.EndOfTurn;
        return EndpointEvent.None;
    }

    /// Return to the pre-speech state (new turn, barge-in, teardown).
    public void Reset()
    {
        Speaking = false;
        UtterancePeak = 0;
        _smoothed = 0;
        SpeechMs = 0;
        SilenceMs = 0;
        _risingTail = false;
        _tail.Clear();
        _recent.Clear();
    }

    private void PushRecent(int dtMs, double amp)
    {
        _recent.Add(new Frame(dtMs, amp));
        var total = _recent.Sum(f => f.Ms);
        while (_recent.Count > 1 && total - _recent[0].Ms >= ExtendedSilenceMs)
        {
            total -= _recent[0].Ms;
            _recent.RemoveAt(0);
        }
    }

    private bool SteadyPause
    {
        get
        {
            if (_recent.Count == 0 || _recent.Sum(f => f.Ms) < ExtendedSilenceMs) return false;
            var loudest = _recent.Max(f => f.Amp);
            var quietest = _recent.Min(f => f.Amp);
            return loudest < UtterancePeak * SteadyPeakRatio
                && loudest <= Math.Max(quietest, SilenceThreshold) * SteadyBandRatio;
        }
    }

    private void PushTail(int dtMs, double amp)
    {
        _tail.Add(new Frame(dtMs, amp));
        var total = _tail.Sum(f => f.Ms);
        while (_tail.Count > 1 && total - _tail[0].Ms >= TailWindowMs * 2)
        {
            total -= _tail[0].Ms;
            _tail.RemoveAt(0);
        }
    }

    private bool ComputeRisingTail()
    {
        if (_tail.Count < 2) return false;
        int recentMs = 0, priorMs = 0;
        double recentSum = 0, priorSum = 0;
        for (var i = _tail.Count - 1; i >= 0; i--)
        {
            var f = _tail[i];
            if (recentMs < TailWindowMs)
            {
                recentMs += f.Ms;
                recentSum += f.Amp * f.Ms;
            }
            else if (priorMs < TailWindowMs)
            {
                priorMs += f.Ms;
                priorSum += f.Amp * f.Ms;
            }
            else
            {
                break;
            }
        }
        if (recentMs == 0 || priorMs == 0) return false;
        return recentSum / recentMs > priorSum / priorMs * RisingTailRatio;
    }

    /// Duration of a mono PCM16 buffer of `byteLength` bytes at `sampleRate`.
    public static int FrameMsForPcm16(int byteLength, int sampleRate)
    {
        if (byteLength <= 0 || sampleRate <= 0) return 0;
        return (int)((long)(byteLength / 2) * 1000 / sampleRate);
    }

    /// Peak amplitude of a mono PCM16-LE chunk, normalized 0..1 (peak, not RMS: the thresholds are
    /// calibrated against peak).
    public static double PeakAmplitude(ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length < 2) return 0;
        var peak = 0.0;
        for (var i = 0; i + 1 < pcm.Length; i += 2)
        {
            var s = (short)(pcm[i] | (pcm[i + 1] << 8));
            var v = Math.Abs(s / 32768.0);
            if (v > peak) peak = v;
        }
        return Math.Clamp(peak, 0, 1);
    }
}
