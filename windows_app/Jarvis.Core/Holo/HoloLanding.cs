namespace Jarvis.Core.Holo;

/// What arriving does for a drop and its action (port of `HoloArrivalPlan`; pure).
public sealed record HoloArrivalPlan
{
    /// The bytes come from the server (or arrived over the LAN).
    public bool Fetch { get; init; }
    /// Saved to Downloads\Holo Drop: the file itself, a .url for a link, a .txt for text.
    public bool Save { get; init; }
    /// Opened right away (a web link in the browser, a file in its app).
    public bool Open { get; init; }
    /// Open was asked but isn't done unprompted (a program, a script, an odd link): the card's
    /// Open button does it.
    public bool OpenHeld { get; init; }
    public bool Copy { get; init; }
    /// Text asked to "open" is shown on the card.
    public bool Show { get; init; }
}

public static class HoloLanding
{
    /// Files of these kinds never open by themselves (Windows' runnable and shortcut types).
    private static readonly HashSet<string> Executables = new(StringComparer.OrdinalIgnoreCase)
    {
        "exe", "com", "scr", "pif", "msi", "msp", "mst", "msix", "msixbundle", "appx", "appxbundle", "appinstaller",
        "application", "bat", "cmd", "ps1", "psm1", "psd1", "ps1xml", "vbs", "vbe", "js", "jse", "wsf", "wsh", "ws",
        "hta", "cpl", "msc", "reg", "inf", "lnk", "url", "website", "scf", "sct", "chm", "jar", "py", "pyw", "rb",
        "pl", "gadget", "settingcontent-ms", "library-ms", "search-ms", "searchconnector-ms", "diagcab", "xll",
        "iso", "img", "vhd", "vhdx", "dll", "sys", "drv", "ocx", "lib", "sh", "bash", "zsh", "command",
        "app", "pkg", "dmg", "appref-ms", "theme", "themepack", "desktopthemepackfile", "mshxml",
    };

    /// The three landing steps an action asks for.
    public static (bool Save, bool Open, bool Copy) Steps(HoloAction a) => (a.Saves(), a.Opens(), a.Copies());

    /// A link saved as a Windows Internet Shortcut.
    public static string LinkFileBody(string url) => $"[InternetShortcut]\r\nURL={url}\r\n";

    public static HoloArrivalPlan Plan(HoloDropRecord drop, HoloAction action, bool executable = false)
    {
        var (save, open, copy) = Steps(action);
        switch (drop.Kind)
        {
            case HoloKind.Link:
            case HoloKind.Text:
                var web = drop.WebUrl != null;
                return new HoloArrivalPlan
                {
                    Save = save,
                    Copy = copy,
                    Open = open && web,
                    OpenHeld = open && !web && drop.Kind == HoloKind.Link,
                    Show = open && !web && drop.Kind == HoloKind.Text,
                };
            default:
                return new HoloArrivalPlan
                {
                    Fetch = true,
                    Save = save,
                    Copy = copy,
                    Open = open && !executable,
                    OpenHeld = open && executable,
                };
        }
    }

    /// Judged on the name as it's written to disk (`HoloFiles.SafeName`: control and format
    /// characters gone, spaces trimmed), so "run.ps1\u0007" or "x.lnk " can't slip past.
    public static bool IsExecutable(string name, string mime)
    {
        var (_, ext) = HoloFiles.Split(HoloFiles.SafeName(name));
        if (Executables.Contains(ext)) return true;
        return mime is "application/x-msdownload" or "application/x-msdos-program" or "application/x-msi"
            or "application/x-executable" or "application/vnd.microsoft.portable-executable";
    }
}
