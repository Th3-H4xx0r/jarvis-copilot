using Jarvis.Core.Link;
using Jarvis.Core.Screen;

namespace Jarvis.Tests.Screen;

public class ShareSignalTests
{
    [Fact] public void Answer_EchoesViewer() => Assert.Equal("{\"sdp\":\"v=0\",\"type\":\"answer\",\"viewer\":\"ph1\"}", J.SortedJson(ShareSignal.Answer("v=0", "ph1")));

    [Fact]
    public void Candidate_Shape() => Assert.Equal("{\"candidate\":{\"candidate\":\"candidate:1\",\"sdpMLineIndex\":0,\"sdpMid\":\"0\"},\"type\":\"candidate\",\"viewer\":\"ph1\"}",
        J.SortedJson(ShareSignal.Candidate("candidate:1", 0, "0", "ph1")));

    [Fact]
    public void Candidate_NoMid_OmitsIt() => Assert.Equal("{\"candidate\":{\"candidate\":\"c\",\"sdpMLineIndex\":1},\"type\":\"candidate\",\"viewer\":\"v\"}",
        J.SortedJson(ShareSignal.Candidate("c", 1, null, "v")));

    [Fact] public void Parse_IgnoresOwnMessages() => Assert.Null(ShareSignal.Parse(J.Parse("{\"from\":\"mac\",\"type\":\"answer\"}")));

    [Fact]
    public void Parse_OfferCandidateBye()
    {
        Assert.Equal(new ShareInbound.Offer("ph1", "v=0"), ShareSignal.Parse(J.Parse("{\"from\":\"viewer\",\"type\":\"offer\",\"viewer\":\"ph1\",\"sdp\":\"v=0\"}")));
        Assert.Equal(new ShareInbound.Candidate("ph1", "candidate:9", 1, "1"),
            ShareSignal.Parse(J.Parse("{\"from\":\"viewer\",\"type\":\"candidate\",\"viewer\":\"ph1\",\"candidate\":{\"candidate\":\"candidate:9\",\"sdpMLineIndex\":1,\"sdpMid\":\"1\"}}")));
        Assert.Equal(new ShareInbound.Bye("ph1"), ShareSignal.Parse(J.Parse("{\"from\":\"viewer\",\"type\":\"bye\",\"viewer\":\"ph1\"}")));
        Assert.Null(ShareSignal.Parse(J.Parse("{\"from\":\"viewer\",\"type\":\"weird\"}")));
    }

    [Fact]
    public void Outbound_AddsFromMac()
    {
        var m = ShareSignal.Outbound(ShareSignal.Answer("v=0", "ph1"));
        Assert.Equal("mac", J.S(m["from"]));
    }

    [Fact]
    public void Mine_LeavesOutGlassesShares()
    {
        // A "glasses" share is this PC ASKING for the glasses' video (GlassesCameraService): nothing
        // to capture here.
        var reply = J.Parse("{\"shares\":[{\"id\":\"g\",\"device_id\":\"pc1\",\"reason\":\"glasses\"},{\"id\":\"a\",\"device_id\":\"pc1\",\"reason\":\"anytime\"}]}");
        Assert.Equal(new[] { ("a", "anytime") }, ShareSelection.Mine(reply, "pc1"));
    }

    [Fact]
    public void Mine_OnlyThisDevice()
    {
        var reply = J.Parse("{\"shares\":[{\"id\":\"a\",\"device_id\":\"pc1\",\"reason\":\"task\"},{\"id\":\"b\",\"device_id\":\"mac1\"},{\"id\":\"c\"},{\"id\":\"d\",\"device_id\":\"pc1\",\"status\":\"ended\"}]}");
        Assert.Equal(new[] { ("a", "task") }, ShareSelection.Mine(reply, "pc1"));
        Assert.Equal(new[] { ("x", "anytime") }, ShareSelection.Mine(J.Parse("{\"shares\":[{\"id\":\"x\",\"device_id\":\"pc1\"}]}"), "pc1"));
    }

    [Fact] public void ListPath() => Assert.Equal("/api/screen/shares?active=1&from=mac&device=pc%201", ShareSelection.ListPath("pc 1"));
    [Fact] public void SignalPath() => Assert.Equal("/api/screen/shares/s1/signal?for=mac&after=7&wait=25", ShareSelection.SignalPath("s1", 7));
    [Fact] public void StopPath() => Assert.Equal("/api/screen/shares/s1/stop", ShareSelection.StopPath("s1"));
    [Fact] public void RecordsReplay_TaskOnly() { Assert.True(ShareSelection.RecordsReplay("task")); Assert.False(ShareSelection.RecordsReplay("anytime")); }

    [Fact]
    public void EarlyCandidates_HeldPerViewer_Capped()
    {
        var e = new EarlyCandidates();
        for (var i = 0; i < 70; i++) e.Hold(new ShareInbound.Candidate("v1", $"c{i}", 0, "0"));
        for (var v = 0; v < 20; v++) e.Hold(new ShareInbound.Candidate($"x{v}", "c", 0, null));
        Assert.True(e.ViewerCount <= 16);
        var taken = e.Take("v1");
        Assert.True(taken.Count <= 64);
        Assert.Empty(e.Take("v1"));
    }

    [Fact]
    public void EarlyCandidates_TakeReturnsInOrder()
    {
        var e = new EarlyCandidates();
        e.Hold(new ShareInbound.Candidate("v", "a", 0, null));
        e.Hold(new ShareInbound.Candidate("v", "b", 0, null));
        Assert.Equal(new[] { "a", "b" }, e.Take("v").Select(c => c.Cand));
        e.Hold(new ShareInbound.Candidate("v", "z", 0, null));
        e.Drop("v");
        Assert.Empty(e.Take("v"));
    }

    [Fact] public void FrameSize_Fits4kTo1440p() => Assert.Equal((2560, 1440), FrameSize.Fit(3840, 2160));
    [Fact] public void FrameSize_KeepsSmallEven() => Assert.Equal((1280, 720), FrameSize.Fit(1281, 721));
    [Fact] public void FrameSize_KeepsA1440pMonitorNative() => Assert.Equal((2560, 1440), FrameSize.Fit(2560, 1440));
    [Fact] public void FrameSize_Keeps1600pNative() => Assert.Equal((2560, 1600), FrameSize.Fit(2560, 1600));
    [Fact] public void FrameSize_UltrawideFitsWidth() => Assert.Equal((2560, 1070), FrameSize.Fit(3440, 1440));

    [Fact]
    public void Vp8Settings_BitrateFollowsTheFrame()
    {
        Assert.Equal(6636u, Vp8Settings.For(2560, 1440, 28).Kbps);
        Assert.Equal(3732u, Vp8Settings.For(1920, 1080, 28).Kbps);
        Assert.Equal(2500u, Vp8Settings.For(640, 360, 28).Kbps);
        Assert.Equal(10_000u, Vp8Settings.For(5120, 2880, 28).Kbps);
    }

    [Fact]
    public void Vp8Settings_ThreadsAreHalfTheCoresUpTo8()
    {
        Assert.Equal(8u, Vp8Settings.For(2560, 1440, 28).Threads);
        Assert.Equal(2u, Vp8Settings.For(2560, 1440, 4).Threads);
        Assert.Equal(1u, Vp8Settings.For(2560, 1440, 1).Threads);
        Assert.Equal(120u, Vp8Settings.For(2560, 1440, 28).KeyEvery);
    }
}
