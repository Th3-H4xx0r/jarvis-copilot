namespace Jarvis.Core.Update;

/// Working directories that never hold the app folder open. A process whose working directory is inside
/// %LOCALAPPDATA%\Programs\Jarvis\app keeps that folder in use, and the updater can't move it aside (live 2026-11-23:
/// every update after the first failed "being used by another process": JarvisUpdater started the new app *in* the
/// app folder, and that app started the next updater, which inherited it).
public static class SafeCwd
{
    /// Jarvis's data folder (%LOCALAPPDATA%\Jarvis): logs, update staging. Never the app folder.
    public static string DataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis");

    public static bool IsInside(string path, string dir)
    {
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(dir)) return false;
        static string Norm(string p) => p.Replace('/', '\\').TrimEnd('\\') + "\\";
        return Norm(path).StartsWith(Norm(dir), StringComparison.OrdinalIgnoreCase);
    }

    /// `candidate` unless it's inside `appDir`; then `fallback`.
    public static string Outside(string candidate, string appDir, string fallback) =>
        IsInside(candidate, appDir) ? fallback : candidate;

    /// Moves this process's own working directory out of `appDir` (to the data folder). Best effort.
    public static void LeaveAppFolder(string appDir)
    {
        try
        {
            if (!IsInside(Environment.CurrentDirectory, appDir)) return;
            Directory.CreateDirectory(DataDir);
            Environment.CurrentDirectory = DataDir;
        }
        catch (Exception) { }
    }
}
