namespace Jarvis.Core.Stats;

/// A game session's summary (the server's sessions table).
public sealed record GameSession(string Id, string Exe, double Start, double End, double FpsAvg, double FpsLow1,
    double CpuTempMax, double GpuTempMax, double EnergyWh, double WattsAvg, double WattsMax, double ThrottleS)
{
    public Dictionary<string, object> ToWire() => new()
    {
        ["id"] = Id, ["exe"] = Exe, ["title"] = Path.GetFileNameWithoutExtension(Exe), ["start"] = Start, ["end"] = End,
        ["fps_avg"] = Math.Round(FpsAvg, 1), ["fps_low1"] = Math.Round(FpsLow1, 1), ["cpu_temp_max"] = CpuTempMax,
        ["gpu_temp_max"] = GpuTempMax, ["energy_wh"] = Math.Round(EnergyWh, 1), ["watts_avg"] = Math.Round(WattsAvg, 1),
        ["watts_max"] = WattsMax, ["throttle_s"] = ThrottleS,
    };
}

/// Follows game mode: a session starts when a game exe is in front (game mode on) and ends when
/// it goes; meanwhile it gathers the frame rate, peak temperatures, energy and throttling.
public sealed class SessionTracker
{
    private string? _exe;
    private double _start, _last, _wh, _wattsSum, _wattsMax, _cpuMax, _gpuMax, _throttle;
    private int _n;
    private readonly List<double> _fps = new();

    public bool Active => _exe != null;

    /// Returns the finished session when the game ends (or switches to another game).
    public GameSession? Update(StatsSample s, string? gameExe, bool throttling = false)
    {
        GameSession? done = null;
        if (_exe != null && !string.Equals(_exe, gameExe, StringComparison.OrdinalIgnoreCase)) done = Finish();
        if (gameExe == null) return done;
        if (_exe == null) { _exe = gameExe; _start = _last = s.T; }
        var dt = Math.Clamp(s.T - _last, 0, 30);
        _last = s.T;
        _n++;
        if (s.R.TryGetValue(ReadingKeys.Fps, out var fps) && fps > 0) _fps.Add(fps);
        if (s.R.TryGetValue(ReadingKeys.PowerTotal, out var w)) { _wattsSum += w; _wattsMax = Math.Max(_wattsMax, w); _wh += w * dt / 3600; }
        if (s.R.TryGetValue(ReadingKeys.CpuTemp, out var ct)) _cpuMax = Math.Max(_cpuMax, ct);
        if (s.R.TryGetValue(ReadingKeys.GpuTemp, out var gt)) _gpuMax = Math.Max(_gpuMax, gt);
        if (throttling) _throttle += dt;
        return done;
    }

    private GameSession Finish()
    {
        var sorted = _fps.OrderBy(v => v).ToList();
        var low1 = sorted.Count == 0 ? 0 : sorted[(int)Math.Floor((sorted.Count - 1) * 0.01)];
        var s = new GameSession($"{(long)_start}-{_exe}", _exe!, _start, _last, sorted.Count == 0 ? 0 : sorted.Average(), low1,
            _cpuMax, _gpuMax, _wh, _n == 0 ? 0 : _wattsSum / _n, _wattsMax, _throttle);
        _exe = null;
        _fps.Clear();
        _wh = _wattsSum = _wattsMax = _cpuMax = _gpuMax = _throttle = 0;
        _n = 0;
        return s;
    }
}
