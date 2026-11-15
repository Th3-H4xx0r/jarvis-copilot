namespace Jarvis.Core.Holo;

/// Holo Drop's temporary copies (received files kept for "open", LAN uploads, zipped folders)
/// all live in `HoloDrop-*` folders of the temp root (port of `HoloTemp`). Swept after a day at
/// launch; never touches anything outside those folders.
public static class HoloTemp
{
    public const string Prefix = "HoloDrop-";
    /// Received files sit one folder per drop in here; it's swept by its children.
    public const string Inbox = "HoloDrop-inbox";

    public static string DefaultRoot => Path.GetTempPath();

    public static void Sweep(string? root = null, TimeSpan? maxAge = null, DateTime? nowUtc = null)
    {
        root ??= DefaultRoot;
        var age = maxAge ?? TimeSpan.FromDays(1);
        var now = nowUtc ?? DateTime.UtcNow;
        bool Old(string p) => now - Directory.GetLastWriteTimeUtc(p) > age;
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(root, Prefix + "*"))
            {
                try
                {
                    if (Path.GetFileName(dir) == Inbox)
                    {
                        foreach (var drop in Directory.EnumerateDirectories(dir))
                            if (Old(drop)) Directory.Delete(drop, true);
                    }
                    else if (Old(dir))
                    {
                        Directory.Delete(dir, true);
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// Deletes the temporary copies an item was made of (each file's own `HoloDrop-*` folder
    /// directly under `root`); his own files are left alone.
    public static void Release(HoloItem? item, string? root = null)
    {
        if (item is not HoloFilesItem files) return;
        var baseDir = Path.GetFullPath(root ?? DefaultRoot).TrimEnd(Path.DirectorySeparatorChar);
        foreach (var p in files.Paths)
        {
            var folder = Path.GetDirectoryName(Path.GetFullPath(p));
            if (folder == null) continue;
            var name = Path.GetFileName(folder);
            if (!string.Equals(Path.GetDirectoryName(folder)?.TrimEnd(Path.DirectorySeparatorChar), baseDir, StringComparison.OrdinalIgnoreCase)
                || !name.StartsWith(Prefix, StringComparison.Ordinal) || name == Inbox) continue;
            try { Directory.Delete(folder, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}
