namespace Jarvis.Core.Unlock;

/// The words on Settings → PC power's unlock rows.
public static class UnlockSetup
{
    public static string HelperLine(bool installed) => installed ? "Installed" : "Not installed";

    /// Install, or Reinstall once it's there: a reinstall carries a newly trusted iPhone's key to the helper.
    public static string HelperButton(bool installed) => installed ? "Reinstall" : "Install";
}
