using Jarvis.Core.Holo;

namespace Jarvis.Tests.Holo;

public class HoloSendDefaultsTests
{
    [Fact]
    public void DefaultActions()
    {
        Assert.Equal(HoloAction.Open, HoloSendDefaults.Action(HoloItem.Link("https://x.example")));
        Assert.Equal(HoloAction.Copy, HoloSendDefaults.Action(HoloItem.Text("hello")));
        Assert.Equal(HoloAction.SaveOpen, HoloSendDefaults.Action(HoloItem.Files(new[] { @"C:\a.pdf" })));
        Assert.Equal(HoloAction.Save, HoloSendDefaults.Action(HoloItem.Files(new[] { @"C:\a.pdf", @"C:\b.png" })));
    }

    [Fact]
    public void Targets_OnlineAndAccepting()
    {
        var devices = new[]
        {
            new HoloDevice("p", "iPhone", "iphone"),
            new HoloDevice("w", "Watch", "watch", Accepts: new[] { "text" }),
            new HoloDevice("o", "Old", "mac", Online: false),
        };
        Assert.Equal(new[] { "p" }, HoloSendDefaults.Targets(devices, HoloItem.Link("https://x.example")).Select(d => d.Id));
        Assert.Equal(new[] { "p", "w" }, HoloSendDefaults.Targets(devices, HoloItem.Text("hi")).Select(d => d.Id));
    }
}
