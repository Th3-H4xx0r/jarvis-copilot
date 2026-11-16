using System.Diagnostics;
using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.State;
using Jarvis.Core.Stats;
using Jarvis.Platform;

namespace Jarvis.Stats;

/// PC Stats on the PC: once a second while the pc-stats integration is on, the sensor helper's
/// readings (or the app's own fallback) go through CollectorLogic, out to the dashboard window
/// (`Sample`) and up to /api/pc-stats/samples. The integration's settings are read every 60 s; a
/// 409 means it's switched off, which stops everything at once.
public sealed class StatsService : IDisposable
{
    private readonly ApiClient _api;
    private readonly AppState _state;
    private readonly SensorPipeClient _pipe = new();
    private readonly CollectorLogic _logic = new(new PowerSettings(), new Thresholds());
    private readonly Action<string> _log = FileLog.For("stats");
    private readonly System.Threading.Timer _tick;
    private int _busy, _uploading;
    private DateTime _settingsAt = DateTime.MinValue;

    public StatsService(ApiClient api, AppState state)
    {
        _api = api;
        _state = state;
        _tick = new System.Threading.Timer(_ => Tick(), null, TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(1));
    }

    /// Each second's sample with its estimated and unavailable readings (on the timer thread).
    public event Action<StatsSample, IReadOnlySet<string>, bool>? Sample;
    /// The integration turned on/off or its settings changed.
    public event Action? SettingsChanged;

    public bool On => _logic.On;
    public bool HelperConnected => _pipe.Connected;
    public GameSession? CurrentSession => _logic.CurrentSession;
    public GameSession? LastSession => _logic.LastSession;
    /// Electricity price per kWh (0 = not set) and its currency, from the integration's settings.
    public double Price => Settings["price"] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
    public string Currency => J.S(Settings["currency"]) is { Length: > 0 } c ? c : "USD";
    public JsonObject Settings { get; private set; } = new();
    public string Monitor => J.S(Settings["monitor"]);
    public bool DriverOn => Settings["sensor_driver"] is not JsonValue v || !v.TryGetValue<bool>(out var b) || b;

    private void Tick()
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            if (DateTime.UtcNow - _settingsAt > TimeSpan.FromSeconds(60) && _state.ApiOrigin != null)
            {
                _settingsAt = DateTime.UtcNow;
                _ = RefreshSettingsAsync();
            }
            if (!_logic.On) return;
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            var helper = DriverOn ? _pipe.Latest() : null;
            var raw = helper?.R ?? PdhFallback.Read();
            var game = GameExe(_state.GameMode.On ? _state.GameMode.Reason : "");
            var frames = game != null && helper != null ? FramesFor(game, helper.Value.Fps) : null;
            if (_logic.Tick(now, raw, frames, game) is { } sample)
                Sample?.Invoke(sample, _logic.Estimated, helper == null);
            if (_logic.DueUpload(now) is { } batch && Interlocked.Exchange(ref _uploading, 1) == 0) _ = UploadAsync(batch);
        }
        catch (Exception e)
        {
            _log("tick failed: " + e.Message);
        }
        finally
        {
            Interlocked.Exchange(ref _busy, 0);
        }
    }

    public async Task RefreshSettingsAsync()
    {
        bool on;
        try
        {
            var reply = await _api.GetAsync("/api/pc-stats/settings", TimeSpan.FromSeconds(10));
            Settings = J.Obj(reply["settings"]);
            on = true;
        }
        catch (ApiException e) when (e.Status == 409) { on = false; }
        catch (ApiException) { return; }
        var was = _logic.On;
        _logic.Power = new PowerSettings(Num("psu_efficiency", 90), Num("cpu_tdp", 0), Num("gpu_tdp", 0));
        _logic.SetThresholds(new Thresholds(Num("warn_gpu_temp", 85), Num("warn_cpu_temp", 95), Num("warn_power_spike", 1.3), Num("warn_fps_drop", 40)));
        _logic.On = on;
        if (on && DriverOn) _pipe.Start(); else _pipe.Stop();
        if (was != on) _log(on ? "on" : "off");
        SettingsChanged?.Invoke();
    }

    private double Num(string key, double fallback) => J.D(Settings[key]) is { } d ? d : fallback;

    private async Task UploadAsync(UploadBatch b)
    {
        try
        {
            if (_state.DeviceId is not { Length: > 0 } device) { _logic.Requeue(b); return; }
            var samples = new JsonArray();
            foreach (var s in b.Samples)
            {
                var r = new JsonObject();
                foreach (var (k, v) in s.R) r[k] = Math.Round(v, 2);
                samples.Add(new JsonObject { ["t"] = s.T, ["r"] = r, ["game"] = s.Game });
            }
            var body = new JsonObject
            {
                ["device_id"] = device,
                ["samples"] = samples,
                ["estimated"] = new JsonArray(b.Estimated.Select(k => (JsonNode)k).ToArray()),
                ["sessions"] = JsonSerializerNode(b.Sessions.Select(x => x.ToWire())),
                ["moments"] = JsonSerializerNode(b.Moments.Select(x => x.ToWire())),
            };
            var reply = await _api.PostAsync("/api/pc-stats/samples", body, TimeSpan.FromSeconds(10));
            _logic.Uploaded(J.B(reply["live"]));
        }
        catch (ApiException e) when (e.Status == 409)
        {
            _logic.On = false;
            _pipe.Stop();
            SettingsChanged?.Invoke();
        }
        catch (ApiException) { _logic.Requeue(b); }
        finally
        {
            Interlocked.Exchange(ref _uploading, 0);
        }
    }

    private static JsonArray JsonSerializerNode(IEnumerable<Dictionary<string, object>> rows) =>
        new(rows.Select(r => (JsonNode)System.Text.Json.JsonSerializer.SerializeToNode(r)!).ToArray());

    /// "fullscreen cod.exe" → "cod.exe".
    public static string? GameExe(string reason) =>
        reason.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault(t => t.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));

    private static (double, double, double)? FramesFor(string exe, Dictionary<int, (double Fps, double Low1, double FrameTime)> fps)
    {
        try
        {
            var pids = Process.GetProcessesByName(System.IO.Path.GetFileNameWithoutExtension(exe)).Select(p => p.Id).ToHashSet();
            return fps.Where(kv => pids.Contains(kv.Key)).OrderByDescending(kv => kv.Value.Fps).Select(kv => ((double, double, double)?)kv.Value).FirstOrDefault();
        }
        catch (InvalidOperationException) { return null; }
    }

    public void Dispose()
    {
        _tick.Dispose();
        _pipe.Dispose();
    }
}
