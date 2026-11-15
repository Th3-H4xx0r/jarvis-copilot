using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Prefs;

/// The app's preferences: one JSON object at %APPDATA%\Jarvis\prefs.json, written atomically.
/// A missing, corrupt or wrongly-typed value reads as the caller's fallback.
public sealed class PrefsStore
{
    private readonly string _path;
    private readonly object _lock = new();
    private JsonObject _values;

    public PrefsStore(string path)
    {
        _path = path;
        _values = Load(path);
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jarvis", "prefs.json");

    public event Action<string>? Changed;

    private static JsonObject Load(string path)
    {
        try
        {
            return File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject o ? o : new JsonObject();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return new JsonObject();
        }
    }

    public T Get<T>(string key, T fallback)
    {
        lock (_lock)
        {
            if (_values[key] is not { } node) return fallback;
            try { return node.Deserialize<T>() ?? fallback; }
            catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return fallback; }
        }
    }

    public T Get<T>(PrefKey<T> key) => Get(key.Name, key.Default);

    public void Set<T>(string key, T value)
    {
        lock (_lock)
        {
            _values[key] = JsonSerializer.SerializeToNode(value);
            Save();
        }
        Changed?.Invoke(key);
    }

    public void Set<T>(PrefKey<T> key, T value) => Set(key.Name, value);

    private void Save()
    {
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, _values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, _path, overwrite: true);
    }
}
