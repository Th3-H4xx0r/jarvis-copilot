namespace Jarvis.Core.Settings;

/// One Settings sidebar entry. Native panes are WPF views registered by id
/// (SettingsWindow.RegisterNative); server panes are the web Settings in WebView2. Core can't
/// hold a FrameworkElement, so the plan's `Func<FrameworkElement>? Native` is the window's
/// registry and this record says only whether the pane is native.
public sealed record SettingsPane(string Id, string Title, string Glyph, bool Native, string? ServerSection,
    string Panel = "settings", string? Embed = null);

public static class SettingsPanes
{
    public static readonly IReadOnlyList<SettingsPane> All = new[]
    {
        new SettingsPane("general", "General", "", true, null),
        new SettingsPane("agents", "Agents", "", true, null),
        new SettingsPane("pc-power", "PC power", "", true, null),
        new SettingsPane("talk", "Talk & wake word", "", true, null),
        new SettingsPane("flow", "Flow", "", true, null),
        new SettingsPane("shortcuts", "Shortcuts", "", true, null),
        new SettingsPane("power", "Power integrations", "", true, null),
        new SettingsPane("glasses-camera", "Glasses camera", "\uE714", true, null),
        new SettingsPane("voice", "Voice", "", false, "voice"),
        new SettingsPane("live", "Live", "", false, "live"),
        new SettingsPane("speech", "Speech", "", false, "speech"),
        new SettingsPane("voices", "Voices", "", false, "voices"),
        new SettingsPane("conversation", "Conversation", "", false, "conversation"),
        new SettingsPane("providers", "Models & providers", "", false, "providers"),
        new SettingsPane("appearance", "Appearance", "", false, "appearance"),
        new SettingsPane("preferences", "Preferences", "", false, "preferences"),
        new SettingsPane("plugins", "Plugins", "", false, "plugins"),
        new SettingsPane("integrations", "Integrations", "", false, "integrations", Panel: "tasks", Embed: "mac-regular"),
        new SettingsPane("system", "System", "", false, "system"),
    };

    public static SettingsPane? Find(string id) => All.FirstOrDefault(p => p.Id == id);
}

public static class ServerSettingsUrl
{
    public static Uri For(string apiOrigin, string section, string panel = "settings", string? embed = null)
    {
        var q = $"?panel={Uri.EscapeDataString(panel)}&section={Uri.EscapeDataString(section)}";
        if (embed != null) q += $"&embed={Uri.EscapeDataString(embed)}";
        return new Uri(apiOrigin.TrimEnd('/') + "/" + q);
    }
}

/// The fixed notes block on General: what Windows can't do, said plainly.
public static class GeneralNotes
{
    public const string IMessage = "iMessage isn't available on Windows: there is no way to read or send iMessages on a PC.";
    public const string Hello = "Admin actions are approved with Face ID on your iPhone, not Windows Hello.";
    public const string NoTyping = "Jarvis never types into the lock screen or Windows' admin prompts.";
    public static readonly IReadOnlyList<string> All = new[] { IMessage, Hello, NoTyping };
}
