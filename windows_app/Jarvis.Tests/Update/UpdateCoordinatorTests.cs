using Jarvis.Core.Update;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Update;

public class UpdateCoordinatorTests
{
    private static readonly UpdateOffer Offer = new(263200000, "1.0.1", "notes", 10, new Uri("https://v.example/JarvisWin.zip"), new string('a', 64));

    [Fact]
    public async Task Hello_ShowsOffer_LaterHidesItOnPush_ActivationAfter15MinShowsAgain()
    {
        var time = new ManualTime();
        var shown = 0;
        var c = new UpdateCoordinator(() => Task.FromResult<UpdateOffer?>(Offer), new AppVersion("1.0.0", 263100000), time);
        c.Show += _ => shown++;
        await c.SignalAsync(null);
        Assert.Equal(1, shown);
        c.Later();
        await c.SignalAsync(new JsonObject());
        await c.PollAsync();
        Assert.Equal(1, shown);
        time.Advance(TimeSpan.FromMinutes(16));
        await c.ActivationAsync();
        Assert.Equal(2, shown);
    }

    [Fact]
    public async Task UnstampedBuild_NeverOffered()
    {
        var shown = 0;
        var c = new UpdateCoordinator(() => Task.FromResult<UpdateOffer?>(Offer), AppVersion.Unstamped, new ManualTime());
        c.Show += _ => shown++;
        await c.SignalAsync(null);
        Assert.Equal(0, shown);
    }

    [Fact]
    public async Task NoOffer_NothingShown()
    {
        var shown = 0;
        var c = new UpdateCoordinator(() => Task.FromResult<UpdateOffer?>(null), new AppVersion("1.0.0", 263100000), new ManualTime());
        c.Show += _ => shown++;
        await c.SignalAsync(null);
        Assert.Equal(0, shown);
    }
}
