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
}
