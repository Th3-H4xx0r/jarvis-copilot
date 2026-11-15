using System.Text.RegularExpressions;

namespace Jarvis.Tests.Fakes;

/// Temp files and folders for tests (left for the OS to clean).
public static class Tmp
{
    public static string Dir()
    {
        var d = Path.Combine(Path.GetTempPath(), "jarvis-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        return d;
    }

    public static string File(string content, string name = "ui.sock")
    {
        var p = Path.Combine(Dir(), name);
        System.IO.File.WriteAllText(p, content);
        return p;
    }

    /// `<a64>` → 64 × "a", `<A64>` → 64 × "A", `<a63>` → 63 × "a" (any letter and count).
    public static string Expand(string body) =>
        Regex.Replace(body, "<([A-Za-z])(\\d+)>", m => new string(m.Groups[1].Value[0], int.Parse(m.Groups[2].Value)));
}
