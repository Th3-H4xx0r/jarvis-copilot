using Jarvis.Core.Prefs;
using Jarvis.Core.Startup;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Prefs;

public class PrefsStoreTests
{
    [Fact]
    public void Prefs_RoundTripAndDefaults()
    {
        var path = Path.Combine(Tmp.Dir(), "Jarvis", "prefs.json");
        var p = new PrefsStore(path);
        string? changed = null;
        p.Changed += k => changed = k;
        p.Set("sound.volume", 0.3);
        p.Set("talk.key", "F13");
        p.Set("island.openOnHover", true);
        Assert.Equal("island.openOnHover", changed);
        var again = new PrefsStore(path);
        Assert.Equal(0.3, again.Get("sound.volume", 0.5));
        Assert.Equal("F13", again.Get("talk.key", ""));
        Assert.True(again.Get("island.openOnHover", false));
        Assert.Equal(7, again.Get("missing", 7));
    }

    [Fact]
    public void Prefs_CorruptFile_FallsBackToDefaults()
    {
        var path = Tmp.File("{not json", "prefs.json");
        var p = new PrefsStore(path);
        Assert.Equal(0.5, p.Get("sound.volume", 0.5));
        p.Set("sound.on", false);
        Assert.False(new PrefsStore(path).Get("sound.on", true));
    }

    [Fact]
    public void Prefs_WrongTypeFallsBack()
    {
        var path = Tmp.File("{\"sound.volume\":\"loud\"}", "prefs.json");
        Assert.Equal(0.5, new PrefsStore(path).Get("sound.volume", 0.5));
    }

    [Fact]
    public void PrefKeys_Defaults()
    {
        Assert.False(PrefKeys.IslandOpenOnHover.Default);
        Assert.Equal("RightAlt", PrefKeys.FlowKey.Default);
        Assert.Equal(0.5, PrefKeys.SoundVolume.Default);
        Assert.True(PrefKeys.WakeEnabled.Default);
        Assert.Equal("primary", PrefKeys.IslandDisplay.Default);
        var p = new PrefsStore(Path.Combine(Tmp.Dir(), "prefs.json"));
        Assert.False(p.Get(PrefKeys.HoloFling));
        p.Set(PrefKeys.HoloFling, true);
        Assert.True(p.Get(PrefKeys.HoloFling));
        Assert.Equal("holo.fling", PrefKeys.HoloFling.Name);
    }
}

public sealed class FakeRegistry : IRegistry
{
    public readonly Dictionary<string, string> Values = new();
    public int Writes;
    public string? GetRunValue(string name) => Values.TryGetValue(name, out var v) ? v : null;
    public void SetRunValue(string name, string? value)
    {
        Writes++;
        if (value == null) Values.Remove(name); else Values[name] = value;
    }
}

public class StartupRegistrationTests
{
    private const string Exe = @"C:\Users\p\AppData\Local\Programs\Jarvis\app\Jarvis.exe";

    [Fact]
    public void Startup_CommandQuotesExe() =>
        Assert.Equal("\"C:\\Users\\p\\AppData\\Local\\Programs\\Jarvis\\app\\Jarvis.exe\" --startup", StartupRegistration.Command(Exe));

    [Fact]
    public void Startup_DefaultAppliedOnce_TurningOffSticks()
    {
        var r = new FakeRegistry();
        var p = new PrefsStore(Path.Combine(Tmp.Dir(), "prefs.json"));
        StartupRegistration.EnsureDefault(r, p, Exe);
        Assert.True(StartupRegistration.IsOn(r));
        Assert.Equal(StartupRegistration.Command(Exe), r.Values[StartupRegistration.ValueName]);
        StartupRegistration.Set(r, Exe, false);
        StartupRegistration.EnsureDefault(r, p, Exe);
        Assert.False(StartupRegistration.IsOn(r));
        Assert.Equal(2, r.Writes);
    }
}
