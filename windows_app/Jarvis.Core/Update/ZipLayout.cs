using System.IO.Compression;

namespace Jarvis.Core.Update;

/// `JarvisWin.zip`'s required shape (C5): root `Jarvis/` holding Jarvis.exe, JarvisUpdater.exe
/// and version.json whose build is exactly the offered one.
public static class ZipLayout
{
    public const string Root = "Jarvis";

    public static string? Problem(string extractedRoot, long offeredBuild)
    {
        var dir = Path.Combine(extractedRoot, Root);
        foreach (var name in new[] { "Jarvis.exe", "JarvisUpdater.exe", "version.json" })
        {
            if (!File.Exists(Path.Combine(dir, name))) return $"The download has no {Root}/{name}.";
        }
        var got = AppVersion.Read(dir).Build;
        return got == offeredBuild ? null : $"The download is build {got}, not the offered {offeredBuild}.";
    }

    /// Unzips into a fresh `dest`, refusing entries that would land outside it.
    public static void Extract(string zip, string dest)
    {
        if (Directory.Exists(dest)) Directory.Delete(dest, recursive: true);
        Directory.CreateDirectory(dest);
        var full = Path.GetFullPath(dest) + Path.DirectorySeparatorChar;
        using var archive = ZipFile.OpenRead(zip);
        foreach (var e in archive.Entries)
        {
            var target = Path.GetFullPath(Path.Combine(dest, e.FullName));
            if (!target.StartsWith(full, StringComparison.Ordinal)) throw new InvalidDataException($"zip entry escapes: {e.FullName}");
            if (e.FullName.EndsWith('/') || e.FullName.EndsWith('\\')) { Directory.CreateDirectory(target); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            e.ExtractToFile(target, overwrite: true);
        }
    }
}
