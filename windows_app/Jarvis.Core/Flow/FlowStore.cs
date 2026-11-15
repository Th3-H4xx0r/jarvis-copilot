using System.Text.Json;
using System.Text.Json.Serialization;

namespace Jarvis.Core.Flow;

/// Flow's own settings and numbers: %APPDATA%\Jarvis\Flow\{settings,stats}.json, written
/// atomically. Text only; no audio is ever kept.
public sealed class FlowStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _dir;

    public FlowStore(string? dir = null) => _dir = dir ?? DefaultDir;

    public static string DefaultDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jarvis", "Flow");

    public FlowSettings LoadSettings() => Load<FlowSettings>("settings.json") ?? FlowSettings.Default;
    public void SaveSettings(FlowSettings s) => Save("settings.json", s);
    public FlowStats LoadStats() => Load<FlowStats>("stats.json") ?? new FlowStats();
    public void SaveStats(FlowStats s) => Save("stats.json", s);

    private T? Load<T>(string name) where T : class
    {
        try
        {
            var p = Path.Combine(_dir, name);
            return File.Exists(p) ? JsonSerializer.Deserialize<T>(File.ReadAllText(p), Options) : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        {
            return null;
        }
    }

    private void Save<T>(string name, T value)
    {
        Directory.CreateDirectory(_dir);
        var p = Path.Combine(_dir, name);
        File.WriteAllText(p + ".tmp", JsonSerializer.Serialize(value, Options));
        File.Move(p + ".tmp", p, overwrite: true);
    }
}
