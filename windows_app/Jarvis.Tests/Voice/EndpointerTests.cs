using Jarvis.Core.Voice;

namespace Jarvis.Tests.Voice;

/// Adaptive end-of-speech detection (port of EndpointerTests.swift).
public class EndpointerTests
{
    /// Feed `ms` of audio at `amp` in `frameMs` frames, returning the first non-None event (and stopping there).
    private static EndpointEvent Feed(Endpointer ep, double amp, int ms, int frameMs = 20)
    {
        var left = ms;
        while (left > 0)
        {
            var dt = left < frameMs ? left : frameMs;
            left -= dt;
            var ev = ep.Update(amp, dt);
            if (ev != EndpointEvent.None) return ev;
        }
        return EndpointEvent.None;
    }

    /// Feed 100 ms frames cycling through `amps` for `ms`; the ms fed when the first event came, or null.
    private static int? FeedCycle(Endpointer ep, double[] amps, int ms)
    {
        int fed = 0, i = 0;
        while (fed < ms)
        {
            fed += 100;
            if (ep.Update(amps[i % amps.Length], 100) != EndpointEvent.None) return fed;
            i++;
        }
        return null;
    }

    private static readonly double[] CarSpeech = { 0.03, 0.045, 0.012, 0.04, 0.035, 0.02, 0.045 };
    private static readonly double[] CarNoise = { 0.005, 0.0096, 0.007, 0.009, 0.006, 0.0085 };

    // VAD hysteresis.

    [Fact]
    public void QuietPhoneSpeechEndsAfterAPause()
    {
        var ep = new Endpointer();
        Feed(ep, 0.025, 1600);
        Assert.True(ep.Speaking);
        Assert.Equal(EndpointEvent.EndOfTurn, Feed(ep, 0.002, 1200));
    }

    [Fact]
    public void ANoisyRoomStillEndsTheTurn()
    {
        var ep = new Endpointer();
        Feed(ep, 0.02, 500);
        Feed(ep, 0.3, 1500);
        Assert.Equal(EndpointEvent.EndOfTurn, Feed(ep, 0.02, 1500));
    }

    [Fact]
    public void QuietRoomNoiseDoesNotCreateATurn()
    {
        var ep = new Endpointer();
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.003, 5000));
        Assert.False(ep.Speaking);
    }

    [Fact]
    public void DoesNotStartATurnBelowTheSpeechThreshold()
    {
        var ep = new Endpointer();
        Assert.Equal(EndpointEvent.None, Feed(ep, Endpointer.SpeechThreshold - 0.01, 2000));
        Assert.False(ep.Speaking);
    }

    [Fact]
    public void StartsATurnOnceTheSpeechThresholdIsCrossed()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 300);
        Assert.True(ep.Speaking);
    }

    [Fact]
    public void EnergyBetweenTheTwoThresholdsKeepsTheTurnOpen()
    {
        var ep = new Endpointer();
        Feed(ep, 0.025, 1000);
        var mid = (Endpointer.SpeechThreshold + Endpointer.SilenceThreshold) / 2;
        Assert.Equal(EndpointEvent.None, Feed(ep, mid, 3000));
        Assert.Equal(0, ep.SilenceMs);
    }

    // Silence budgets.

    [Fact]
    public void EndsANormalUtteranceAfterTheBaseSilenceWindow()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 1500);
        Assert.Equal(Endpointer.BaseSilenceMs, ep.RequiredSilenceMs);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, Endpointer.BaseSilenceMs - 40));
        Assert.Equal(EndpointEvent.EndOfTurn, Feed(ep, 0.0, 80));
    }

    [Fact]
    public void AShortUtteranceWaitsTheExtendedSilenceWindow()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 400);
        Assert.Equal(Endpointer.ExtendedSilenceMs, ep.RequiredSilenceMs);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, Endpointer.BaseSilenceMs + 100));
        Assert.Equal(EndpointEvent.EndOfTurn,
            Feed(ep, 0.0, Endpointer.ExtendedSilenceMs - Endpointer.BaseSilenceMs - 100 + 40));
    }

    [Fact]
    public void ARisingEnergyTailWaitsTheExtendedSilenceWindow()
    {
        var ep = new Endpointer();
        Feed(ep, 0.15, 1000);
        Feed(ep, 0.60, 200);
        Assert.Equal(Endpointer.ExtendedSilenceMs, ep.RequiredSilenceMs);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, Endpointer.BaseSilenceMs + 100));
    }

    [Fact]
    public void AFallingEnergyTailUsesTheBaseSilenceWindow()
    {
        var ep = new Endpointer();
        Feed(ep, 0.60, 1000);
        Feed(ep, 0.15, 200);
        Assert.Equal(Endpointer.BaseSilenceMs, ep.RequiredSilenceMs);
        Assert.Equal(EndpointEvent.EndOfTurn, Feed(ep, 0.0, Endpointer.BaseSilenceMs + 40));
    }

    [Fact]
    public void SpeechResumingInsideTheSilenceWindowCancelsTheEndpoint()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 1000);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, 300));
        Feed(ep, 0.30, 200);
        Assert.Equal(0, ep.SilenceMs);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, 300));
    }

    // Guards.

    [Fact]
    public void ASubMinimumBlipNeverEndsATurnAndResetsTheDetector()
    {
        var ep = new Endpointer();
        Feed(ep, 0.50, 100);
        Assert.True(ep.Speaking);
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.0, 5000));
        Assert.False(ep.Speaking);
    }

    [Fact]
    public void EndsTheTurnAtTheMaxUtteranceLengthEvenWithoutSilence()
    {
        var ep = new Endpointer();
        Assert.Equal(EndpointEvent.None, Feed(ep, 0.50, Endpointer.MaxUtteranceMs - 200));
        Assert.Equal(EndpointEvent.EndOfTurn, Feed(ep, 0.50, 400));
    }

    [Fact]
    public void ResetReturnsTheDetectorToThePreSpeechState()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 1000);
        Feed(ep, 0.0, 100);
        ep.Reset();
        Assert.False(ep.Speaking);
        Assert.Equal(0, ep.SpeechMs);
        Assert.Equal(0, ep.SilenceMs);
    }

    [Fact]
    public void VoicedMsExcludesTheTrailingSilence()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 1000);
        Feed(ep, 0.0, 200);
        Assert.Equal(1000, ep.VoicedMs);
        Assert.Equal(1200, ep.SpeechMs);
    }

    [Fact]
    public void NegativeOrZeroFrameDurationsAreIgnored()
    {
        var ep = new Endpointer();
        Assert.Equal(EndpointEvent.None, ep.Update(0.5, -50));
        Assert.Equal(0, ep.SpeechMs);
    }

    // frameMsForPcm16 / peak amplitude.

    [Fact]
    public void ConvertsAPcm16MonoByteCountToMilliseconds()
    {
        Assert.Equal(100, Endpointer.FrameMsForPcm16(3200, 16000));
        Assert.Equal(64, Endpointer.FrameMsForPcm16(2048, 16000));
        Assert.Equal(0, Endpointer.FrameMsForPcm16(0, 16000));
    }

    [Fact]
    public void PeakAmplitudeIsTheLoudestSampleNormalized()
    {
        // Samples 0, 16384, -32768 (little-endian).
        var pcm = new byte[] { 0x00, 0x00, 0x00, 0x40, 0x00, 0x80 };
        Assert.Equal(1.0, Endpointer.PeakAmplitude(pcm));
        Assert.Equal(0.5, Endpointer.PeakAmplitude(pcm.AsSpan(0, 4)));
        Assert.Equal(0, Endpointer.PeakAmplitude(new byte[] { 0x7F }));
    }

    // Faster than the old fixed 1500 ms.

    [Fact]
    public void ANormalUtteranceEndpointsWellUnderTheLegacyConstant()
    {
        var ep = new Endpointer();
        Feed(ep, 0.30, 1200);
        var silence = 0;
        while (silence < 1500)
        {
            if (ep.Update(0.0, 20) == EndpointEvent.EndOfTurn) break;
            silence += 20;
        }
        Assert.True(silence < 1500);
        Assert.True(silence <= Endpointer.BaseSilenceMs);
    }

    // Steady background noise (a car).

    [Fact]
    public void SteadyCarNoiseAfterAQuietTalkerEndsTheTurn()
    {
        var ep = new Endpointer();
        Assert.Null(FeedCycle(ep, CarNoise, 1000));
        Assert.Null(FeedCycle(ep, CarSpeech, 2100));
        Assert.True(ep.Speaking);
        var waited = FeedCycle(ep, CarNoise, 3000);
        Assert.NotNull(waited);
        Assert.True(waited <= Endpointer.ExtendedSilenceMs + 200);
    }

    [Fact]
    public void AQuietTalkerInTheCarIsNotCutOffMidSentence()
    {
        var ep = new Endpointer();
        FeedCycle(ep, CarNoise, 1000);
        Assert.Null(FeedCycle(ep, CarSpeech, 8000));
    }

    [Fact]
    public void ABreathInTheCarDoesNotEndTheTurn()
    {
        var ep = new Endpointer();
        FeedCycle(ep, CarSpeech, 2100);
        Assert.Null(FeedCycle(ep, CarNoise, Endpointer.ExtendedSilenceMs - 200));
        Assert.Null(FeedCycle(ep, CarSpeech, 1400));
        Assert.True(ep.Speaking);
    }

    [Fact]
    public void LoudSteadyNoiseAloneIsNotEndedEarly()
    {
        var ep = new Endpointer();
        Assert.Null(FeedCycle(ep, new[] { 0.02, 0.026, 0.022 }, 5000));
    }
}
