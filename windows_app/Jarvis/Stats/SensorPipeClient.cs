using System.IO;
using System.IO.Pipes;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Stats;

/// The JarvisSensors service's pipe: reads its one-line-a-second readings on a background
/// thread and keeps the newest. Connected only while PC Stats is on (the service idles otherwise).
public sealed class SensorPipeClient : IDisposable
{
    private readonly object _lock = new();
    private CancellationTokenSource? _cts;
    private (double T, Dictionary<string, double> R, Dictionary<int, (double, double, double)> Fps)? _latest;

    public bool Connected { get; private set; }

    public void Start()
    {
        if (_cts != null) return;
        var cts = _cts = new CancellationTokenSource();
        new Thread(() => Loop(cts.Token)) { IsBackground = true, Name = "sensor-pipe" }.Start();
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts = null;
        Connected = false;
        lock (_lock) _latest = null;
    }

    /// The newest reading if it's under 3 s old.
    public (Dictionary<string, double> R, Dictionary<int, (double Fps, double Low1, double FrameTime)> Fps)? Latest()
    {
        lock (_lock)
        {
            if (_latest is not { } l || DateTimeOffset.UtcNow.ToUnixTimeSeconds() - l.T > 3) return null;
            return (l.R, l.Fps);
        }
    }

    private void Loop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", "JarvisSensors", PipeDirection.InOut);
                pipe.Connect(2000);
                Connected = true;
                using var reader = new StreamReader(pipe);
                while (!ct.IsCancellationRequested && reader.ReadLine() is { } line) Parse(line);
            }
            catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException or InvalidOperationException) { }
            Connected = false;
            if (ct.WaitHandle.WaitOne(5000)) return;   // the service isn't installed/running: look again shortly
        }
    }

    private void Parse(string line)
    {
        JsonObject o;
        try { o = J.Parse(line); }
        catch (Exception) { return; }
        var r = new Dictionary<string, double>();
        foreach (var (k, v) in J.Obj(o["r"])) if (J.D(v) is { } d) r[k] = d;
        var fps = new Dictionary<int, (double, double, double)>();
        foreach (var (k, v) in J.Obj(o["fps"]))
            if (int.TryParse(k, out var pid) && v is JsonObject f) fps[pid] = (J.D(f["fps"]) ?? 0, J.D(f["low1"]) ?? 0, J.D(f["frametime"]) ?? 0);
        lock (_lock) _latest = (J.D(o["t"]) ?? 0, r, fps);
    }

    public void Dispose() => Stop();
}
