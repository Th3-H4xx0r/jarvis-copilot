namespace Jarvis.Core.Unlock;

/// The words on Settings → PC power's unlock rows.
public static class UnlockSetup
{
    public static string HelperLine(bool installed) => installed ? "Installed" : "Not installed";
}
