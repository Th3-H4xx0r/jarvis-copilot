namespace Jarvis.Platform;

/// Plain text logs in %LOCALAPPDATA%\Jarvis\logs (voice.log, screen.log, update.log, …), one line
/// per event with a UTC time, capped at 2 MB (then rolled to .1).
public static class FileLog
{
    private static readonly object Lock = new();

    public static string Dir => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis", "logs");

    public static Action<string> For(string name) => line => Write(name, line);

    public static void Write(string name, string line)
    {
        try
        {
            lock (Lock)
            {
                System.IO.Directory.CreateDirectory(Dir);
                var path = System.IO.Path.Combine(Dir, name + ".log");
                var info = new System.IO.FileInfo(path);
                if (info.Exists && info.Length > 2_000_000) System.IO.File.Move(path, path + ".1", overwrite: true);
                System.IO.File.AppendAllText(path, $"{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
    }
}
