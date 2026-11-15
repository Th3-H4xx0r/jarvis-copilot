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
    public void Scale_Nearest()
    {
        // 4×1: red, green, blue, white → 2×1 keeps the first and third.
        var src = new byte[] { 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255 };
        var d = FramePixels.ScaleBgra(src, 4, 1, 16, 2, 1);
        Assert.Equal(new byte[] { 0, 0, 255, 255, 255, 0, 0, 255 }, d);
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
