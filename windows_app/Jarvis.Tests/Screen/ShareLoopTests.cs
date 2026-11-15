using Jarvis.Core.Link;
using Jarvis.Core.Screen;

namespace Jarvis.Tests.Screen;

public class ShareLoopTests
{
    [Fact]
    public void Batch_AdvancesSeq_KeepsViewerMessages()
    {
        var (seq, inbound, ended) = ShareSignal.Batch(J.Parse(
            "{\"messages\":[{\"seq\":4,\"from\":\"viewer\",\"viewer\":\"ph\",\"type\":\"offer\",\"sdp\":\"v=0\"},{\"seq\":5,\"from\":\"mac\",\"type\":\"answer\"}]}"), 3);
        Assert.Equal(5, seq);
        Assert.Equal(new ShareInbound.Offer("ph", "v=0"), Assert.Single(inbound));
        Assert.False(ended);
    }

    [Fact]
    public void Batch_EndedByStatusOr404()
    {
        Assert.True(ShareSignal.Batch(J.Parse("{\"status\":\"ended\"}"), 0).Ended);
        Assert.True(ShareSignal.Batch(J.Parse("{\"_status\":410}"), 0).Ended);
        Assert.Equal(7, ShareSignal.Batch(J.Parse("{}"), 7).Seq);
    }

    [Fact]
    public void I420_WhiteAndBlack()
    {
        var white = Enumerable.Repeat((byte)255, 2 * 2 * 4).ToArray();
        var i420 = FramePixels.BgraToI420(white, 2, 2);
        Assert.Equal(6, i420.Length);
        Assert.All(i420.Take(4), y => Assert.Equal(235, y));
        Assert.Equal(128, i420[4]);
        Assert.Equal(128, i420[5]);
        var black = new byte[16];
        Assert.All(FramePixels.BgraToI420(black, 2, 2).Take(4), y => Assert.Equal(16, y));
    }

    [Fact]
    public void I420_ColourIsTheBlockAverage()
    {
        // One red pixel in a 2×2 of black: the block's colour is a quarter red, not all red.
        var px = new byte[16];
        px[2] = 255;
        var i420 = FramePixels.BgraToI420(px, 2, 2);
        Assert.Equal(156, i420[5]);   // V for mean red 63 (all-red would be 239)
    }

    [Fact]
    public void Scale_AveragesArea()
    {
        // 4×1: red, green, blue, white → 2×1 averages each pair (red+green, blue+white).
        var src = new byte[] { 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255 };
        var d = FramePixels.ScaleBgra(src, 4, 1, 16, 2, 1);
        Assert.Equal(new byte[] { 0, 127, 127, 255, 255, 127, 127, 255 }, d);
    }

    [Fact]
    public void Ice_ParsesStringOrList_DefaultsToStun()
    {
        var ice = ShareSignal.IceServers(J.Parse("{\"ice_servers\":[{\"urls\":\"stun:a\"},{\"urls\":[\"turn:b\",\"turns:c\"],\"username\":\"u\",\"credential\":\"p\"},{\"urls\":[]}]}"));
        Assert.Equal(2, ice.Count);
        Assert.Equal(new[] { "turn:b", "turns:c" }, ice[1].Urls);
        Assert.Equal("u", ice[1].Username);
        Assert.Equal(ShareSelection.DefaultStun, Assert.Single(ShareSignal.IceServers(null)).Urls[0]);
    }
}
