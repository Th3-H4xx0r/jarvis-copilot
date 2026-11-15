using Jarvis.Core.Prefs;

namespace Jarvis.Core.Startup;

/// The HKCU Run key, behind an interface so the rule is testable anywhere.
public interface IRegistry
{
    string? GetRunValue(string name);
    void SetRunValue(string name, string? value);
}

/// Open at login: on by default the first time, and turning it off sticks.
public static class StartupRegistration
{
    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "Jarvis";

    public static string Command(string exe) => $"\"{exe}\" --startup";

    public static void EnsureDefault(IRegistry r, PrefsStore p, string exe)
    {
        if (p.Get(PrefKeys.LoginDefaultApplied)) return;
        r.SetRunValue(ValueName, Command(exe));
        p.Set(PrefKeys.LoginDefaultApplied, true);
    }

    public static bool IsOn(IRegistry r) => r.GetRunValue(ValueName) != null;

    public static void Set(IRegistry r, string exe, bool on) => r.SetRunValue(ValueName, on ? Command(exe) : null);
}
