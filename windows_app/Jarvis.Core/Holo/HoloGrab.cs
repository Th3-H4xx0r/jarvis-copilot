using Jarvis.Core.Platform;

namespace Jarvis.Core.Holo;

/// What the grab can read from the window in front. The real one (windows_app/Jarvis/HoloDrop/
/// HoloFrontProbe.cs) uses UIA for the address bar and the selection and `Shell.Application`
/// for Explorer; tests pass a fake. Only read on his key press.
public interface IHoloFrontProbe
{
    FrontWindow? Front();
    string? BrowserUrl(FrontWindow w);
    IReadOnlyList<string> ExplorerSelection(IntPtr hwnd);
    string? DocumentPath(FrontWindow w);
    string? SelectedText(FrontWindow w);
}

/// "Grab what's in front" (port of `HoloGrab`, Ctrl+Alt+H): the browser's page, else Explorer's
/// selected files, else the front document, else the selected text, else nothing (the Orbit then
/// asks to paste or drop a file).
public static class HoloGrab
{
    /// Browsers by exe, with the suffix their window titles carry.
    public static readonly IReadOnlyDictionary<string, string[]> Browsers = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
    {
        ["chrome.exe"] = new[] { " - Google Chrome" },
        ["msedge.exe"] = new[] { " - Microsoft\u200b Edge", " - Microsoft Edge" },
        ["brave.exe"] = new[] { " - Brave" },
        ["vivaldi.exe"] = new[] { " - Vivaldi" },
        ["firefox.exe"] = new[] { " — Mozilla Firefox", " - Mozilla Firefox" },
        ["opera.exe"] = new[] { " - Opera" },
        ["arc.exe"] = Array.Empty<string>(),
    };

    public const string Explorer = "explorer.exe";

    public static HoloItem? Grab(IHoloFrontProbe p, Func<string, bool> exists)
    {
        if (p.Front() is not { } w) return null;
        var exe = Path.GetFileName(w.Exe);
        if (Browsers.TryGetValue(exe, out var suffixes)
            && PageUrl(w.Url ?? p.BrowserUrl(w)) is { } url)
            return HoloItem.Link(url, PageTitle(w.Title, suffixes));
        if (exe.Equals(Explorer, StringComparison.OrdinalIgnoreCase))
        {
            var paths = p.ExplorerSelection(w.Hwnd).Select(s => s.Trim()).Where(s => s.Length > 0 && exists(s)).ToList();
            if (paths.Count > 0) return HoloItem.Files(paths);
        }
        if (p.DocumentPath(w) is { } doc && DocumentItem(doc, exists) is { } item) return item;
        if (p.SelectedText(w) is { } text && HoloItem.FromText(text) is { } t) return t;
        return null;
    }

    /// The address bar's text as a web address: Chromium hides "https://", so a bare host gets it
    /// back. Anything that isn't http(s) (chrome://, about:, a search) is no page.
    public static string? PageUrl(string? raw)
    {
        var t = (raw ?? "").Trim();
        if (t.Length == 0 || t.Any(char.IsWhiteSpace)) return null;
        if (!t.Contains("://", StringComparison.Ordinal))
        {
            if (t.Contains(':') && !t.Split('/')[0].Contains('.')) return null;   // about:blank, edge:settings
            t = "https://" + t;
        }
        return HoloItem.WebUri(t) != null ? t : null;
    }

    private static string? PageTitle(string title, string[] suffixes)
    {
        var t = title.Trim();
        foreach (var s in suffixes)
        {
            if (t.EndsWith(s, StringComparison.Ordinal)) { t = t[..^s.Length].Trim(); break; }
        }
        return t.Length == 0 ? null : t;
    }

    /// The front document: a file URL, a plain Windows path, or (in some apps) a web address.
    public static HoloItem? DocumentItem(string raw, Func<string, bool> exists)
    {
        var t = raw.Trim();
        if (t.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            if (!Uri.TryCreate(t, UriKind.Absolute, out var f)) return null;
            var path = Uri.UnescapeDataString(f.AbsolutePath);
            if (path.Length > 2 && path[0] == '/' && path[2] == ':') path = path[1..];   // /C:/x → C:/x
            if (f.IsUnc) path = f.LocalPath;
            return exists(path) ? HoloItem.Files(new[] { path }) : null;
        }
        if (HoloItem.WebUri(t) is not null) return HoloItem.Link(t);
        var windowsPath = t.Length > 2 && char.IsAsciiLetter(t[0]) && t[1] == ':' && (t[2] == '\\' || t[2] == '/');
        if ((windowsPath || t.StartsWith(@"\\", StringComparison.Ordinal) || t.StartsWith('/')) && exists(t))
            return HoloItem.Files(new[] { t });
        return null;
    }
}
