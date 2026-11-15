using System.Globalization;

namespace Jarvis.Core.Holo;

/// File names for what lands in Downloads\Holo Drop (port of `HoloFiles`, plus Windows' rules:
/// no `\ / : * ? " &lt; &gt; |`, no trailing dots or spaces, no reserved device names).
public static class HoloFiles
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// A name safe for the file system: no path separators or control characters, not hidden,
    /// not empty, at most 120 characters (the extension kept).
    public static string SafeName(string raw, string fallback = "Holo Drop")
    {
        var chars = raw.Select(c => c is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' ? '-' : c)
            .Where(c => !char.IsControl(c) && CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.Format);
        var s = new string(chars.ToArray()).Trim();
        s = s.TrimStart('.');
        s = s.TrimEnd('.', ' ');
        if (s.Length == 0) s = fallback;
        var (stem, ext) = Split(s);
        if (Reserved.Contains(stem)) s = "_" + s;
        if (s.Length > 120)
        {
            (stem, ext) = Split(s);
            s = ext.Length == 0 ? s[..120] : stem[..Math.Max(1, 119 - ext.Length)] + "." + ext;
        }
        return s;
    }

    /// `name`, or "name 2.ext", "name 3.ext"… — the first not in `taken`.
    public static string Unique(string name, Func<string, bool> taken)
    {
        if (!taken(name)) return name;
        var (stem, ext) = Split(name);
        var dotExt = ext.Length == 0 ? "" : "." + ext;
        for (var n = 2; n <= 9_999; n++)
        {
            var candidate = $"{stem} {n}{dotExt}";
            if (!taken(candidate)) return candidate;
        }
        return $"{stem} {Guid.NewGuid().ToString("N")[..8]}{dotExt}";
    }

    /// NSString's stem/extension: the extension follows the last dot that isn't the first character.
    internal static (string Stem, string Ext) Split(string name)
    {
        var i = name.LastIndexOf('.');
        return i > 0 && i < name.Length - 1 ? (name[..i], name[(i + 1)..]) : (name, "");
    }
}
