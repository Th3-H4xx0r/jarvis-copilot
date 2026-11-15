namespace Jarvis.Core.Prefs;

public sealed record PrefKey<T>(string Name, T Default);

/// Every preference the app uses, with its default.
public static class PrefKeys
{
    public static readonly PrefKey<bool> IslandOpenOnHover = new("island.openOnHover", false);
    public static readonly PrefKey<bool> IslandHideWhenIdle = new("island.hideWhenIdle", false);
    public static readonly PrefKey<bool> IslandShowWhileWorking = new("island.showWhileWorking", false);
    public static readonly PrefKey<string> IslandDisplay = new("island.display", "primary");
    public static readonly PrefKey<bool> SoundOn = new("sound.on", true);
    public static readonly PrefKey<double> SoundVolume = new("sound.volume", 0.5);
    public static readonly PrefKey<bool> OrbDesktop = new("orb.desktop", false);
    public static readonly PrefKey<bool> WakeEnabled = new("wake.enabled", true);
    public static readonly PrefKey<string> TalkKey = new("talk.key", "");
    public static readonly PrefKey<bool> FlowEnabled = new("flow.enabled", false);
    public static readonly PrefKey<string> FlowKey = new("flow.key", "RightAlt");
    public static readonly PrefKey<bool> HoloFling = new("holo.fling", false);
    public static readonly PrefKey<bool> LoginDefaultApplied = new("login.defaultApplied", false);
}
