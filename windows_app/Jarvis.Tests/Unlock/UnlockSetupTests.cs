using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Unlock;

public class UnlockSetupTests
{
    [Fact]
    public void HelperButton_InstalledHelperCanBeReinstalled()
    {
        // An installed helper must still be reinstallable: that is how it picks up a newly trusted
        // iPhone's key (bug sweep B4).
        Assert.Equal("Install", UnlockSetup.HelperButton(false));
        Assert.Equal("Reinstall", UnlockSetup.HelperButton(true));
    }
}
