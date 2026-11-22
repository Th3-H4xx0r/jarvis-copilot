using Jarvis.Core.GlassesCamera;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.GlassesCamera;

/// The Jarvis Glasses camera's pure rules (the Mac's GlassesCameraLogic/Kit, ported).
public class GlassesCamTests
{
    private static readonly DateTimeOffset T0 = TestClock.T0;

    [Fact]
    public void DemandAsksWhileInUseAndLingers15s()
    {
        var d = new GlassesCamDemand();
        Assert.False(d.Wanted(installed: true, clients: 0, T0));                 // nothing has used it yet
        Assert.True(d.Wanted(installed: true, clients: 1, T0));
        Assert.True(d.Wanted(installed: true, clients: 0, T0.AddSeconds(14.9)));  // the linger
        Assert.False(d.Wanted(installed: true, clients: 0, T0.AddSeconds(15)));
        Assert.True(d.Wanted(installed: true, clients: 2, T0.AddSeconds(20)));
        Assert.False(d.Wanted(installed: false, clients: 2, T0.AddSeconds(21)));  // removed: stop at once
        Assert.False(d.Wanted(installed: true, clients: 0, T0.AddSeconds(22)));   // and the linger is gone with it
    }

    [Fact]
    public void DemandAsksWhenTheCountIsUnknown()
    {
        var d = new GlassesCamDemand();
        Assert.True(d.Wanted(installed: true, clients: null, T0));
        Assert.False(d.Wanted(installed: false, clients: null, T0));
    }

    [Fact]
    public void PhaseOfCoversEachState()
    {
        GlassesCamPhase Of(bool installed = true, bool wanted = true, bool online = true, bool asked = true,
            GlassesCamPeerState? peer = GlassesCamPeerState.Connected, bool fresh = true, string? failure = null) =>
            GlassesCamPhases.Of(installed, wanted, online, asked, peer, fresh, failure);

        Assert.Equal(GlassesCamPhase.NotInstalled, Of(installed: false));
        Assert.Equal(GlassesCamPhase.Failed, Of(failure: "Reinstall the camera."));
        Assert.Equal(GlassesCamPhase.Idle, Of(wanted: false));
        Assert.Equal(GlassesCamPhase.Offline, Of(online: false));
        Assert.Equal(GlassesCamPhase.Connecting, Of(asked: false));
        Assert.Equal(GlassesCamPhase.WaitingForPhone, Of(peer: null));
        Assert.Equal(GlassesCamPhase.WaitingForPhone, Of(peer: GlassesCamPeerState.Failed));
        Assert.Equal(GlassesCamPhase.WaitingForPhone, Of(peer: GlassesCamPeerState.Disconnected));
        Assert.Equal(GlassesCamPhase.Connecting, Of(peer: GlassesCamPeerState.Connecting));
        Assert.Equal(GlassesCamPhase.Connected, Of(fresh: false));
        Assert.Equal(GlassesCamPhase.Live, Of());

        // Every phase has words, and the iPhone step names the computer camera (not the Mac's).
        foreach (var p in Enum.GetValues<GlassesCamPhase>()) Assert.False(string.IsNullOrWhiteSpace(p.Text()));
        Assert.Contains("Send to computer camera", GlassesCamPhase.WaitingForPhone.Text());
        Assert.Equal("Reinstall the camera.", GlassesCamPhase.Failed.Text("Reinstall the camera."));
        Assert.Equal("Showing your glasses' live video.", GlassesCamPhase.Live.Text());
    }

    [Fact]
    public void FitPortraitIntoLandscapeIsACentredEvenPillar()
    {
        Assert.Equal((438, 0, 404, 720), GlassesCamGeometry.Fit(GlassesCamSpec.Portrait, GlassesCamSpec.Landscape));
        Assert.Equal((0, 0, 720, 1280), GlassesCamGeometry.Fit(GlassesCamSpec.Portrait, GlassesCamSpec.Portrait));
        // A landscape picture into the portrait frame: a centred band, full width.
        Assert.Equal((0, 438, 720, 404), GlassesCamGeometry.Fit((1280, 720), GlassesCamSpec.Portrait));
        // Nothing to fit: the whole target.
        Assert.Equal((0, 0, 1280, 720), GlassesCamGeometry.Fit((0, 0), GlassesCamSpec.Landscape));
        // Always even, never past the target.
        var r = GlassesCamGeometry.Fit((641, 479), (321, 241));
        Assert.True(r.W % 2 == 0 && r.H % 2 == 0 && r.X + r.W <= 321 && r.Y + r.H <= 241);
    }

    [Fact]
    public void SpecMatchesTheMac()
    {
        Assert.Equal("Jarvis Glasses", GlassesCamSpec.Name);
        Assert.Equal(new[] { (720, 1280), (1280, 720) }, GlassesCamSpec.Formats);
        Assert.Equal(TimeSpan.FromSeconds(2), GlassesCamSpec.StaleAfter);
        Assert.Equal(TimeSpan.FromSeconds(15), GlassesCamSpec.Linger);
        Assert.True(Guid.TryParse(GlassesCamSpec.SourceClsid, out _));
    }
}
