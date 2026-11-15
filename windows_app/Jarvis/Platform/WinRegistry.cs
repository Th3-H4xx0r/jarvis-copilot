using Jarvis.Core.Startup;
using Microsoft.Win32;

namespace Jarvis.Platform;

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run (no elevation needed).
public sealed class WinRegistry : IRegistry
{
    public string? GetRunValue(string name)
    {
        using var key = Registry.CurrentUser.OpenSubKey(StartupRegistration.RunKey);
        return key?.GetValue(name) as string;
    }

    public void SetRunValue(string name, string? value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(StartupRegistration.RunKey, writable: true);
        if (value == null) key.DeleteValue(name, throwOnMissingValue: false);
        else key.SetValue(name, value, RegistryValueKind.String);
    }
}
