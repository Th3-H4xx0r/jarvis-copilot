using Jarvis.Core.Music;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Music;

public class NowPlayingTests
{
    [Fact]
    public void NowPlaying_PositionRunsWhilePlaying()
    {
        var playing = new NowPlaying("Spotify", "Song", "Artist", "", 200, 10, T0, true);
        Assert.Equal(15, playing.PositionAt(T0.AddSeconds(5)));
        Assert.Equal(10, (playing with { IsPlaying = false }).PositionAt(T0.AddSeconds(5)));
        Assert.Equal(200, playing.PositionAt(T0.AddSeconds(500)));
    }

    [Fact]
    public void Clock_MinutesAndHours()
    {
        Assert.Equal("3:07", NowPlaying.Clock(187.9));
        Assert.Equal("1:02:03", NowPlaying.Clock(3723));
        Assert.Equal("0:00", NowPlaying.Clock(-4));
    }

    [Fact]
    public void Remaining_RoundsUp_BlankWithoutDuration()
    {
        Assert.Equal("-1:01", NowPlaying.Remaining(120, 59.5));
        Assert.Equal("", NowPlaying.Remaining(0, 3));
    }
}
