using System.Collections.Concurrent;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Session;

namespace JarvisSensors;

/// Frame timing per process from Windows' own present events (the PresentMon method, no
/// injection): Microsoft-Windows-DXGI event 42 (Present start) for DXGI games, and
/// Microsoft-Windows-DxgKrnl event 215 (PresentHistoryDetailed start, keyword Present) for
/// everything else (OpenGL, Vulkan). A process with DXGI presents is counted from DXGI only, so
/// no frame counts twice. Runs only while the app is connected.
internal sealed class Frames : IDisposable
{
    private static readonly Guid Dxgi = new("CA11C036-0102-4A2D-A6AD-F03CFED5D3C9");
    private static readonly Guid DxgKrnl = new("802ec45a-1e99-4b83-9920-87c98277ba9d");
    private const ulong PresentKeyword = 0x8000000;
    private readonly ConcurrentDictionary<int, Track> _tracks = new();
    private TraceEventSession? _session;
    private Thread? _thread;

    private sealed class Track
    {
        public readonly Queue<double> Dxgi = new(), Kernel = new();
    }

    public void Start()
    {
        if (_session != null) return;
        try
        {
            _session = new TraceEventSession("JarvisSensorsFrames") { StopOnDispose = true };
            // Only the two events used, filtered by Windows itself (DxgKrnl's Present keyword alone
            // still sends thousands of scheduler events a second); payloads are never decoded.
            _session.EnableProvider(Dxgi, TraceEventLevel.Informational, ulong.MaxValue,
                new TraceEventProviderOptions { EventIDsToEnable = new List<int> { 42 } });
            _session.EnableProvider(DxgKrnl, TraceEventLevel.Informational, PresentKeyword,
                new TraceEventProviderOptions { EventIDsToEnable = new List<int> { 215 } });
            _session.Source.AllEvents += OnEvent;
            _thread = new Thread(() => { try { _session?.Source.Process(); } catch (Exception) { } }) { IsBackground = true, Name = "frames" };
            _thread.Start();
        }
        catch (Exception e)
        {
            Log.Write("frames unavailable: " + e.Message);
            Stop();
        }
    }

    private void OnEvent(TraceEvent e)
    {
        var id = (int)e.ID;
        bool dxgi = e.ProviderGuid == Dxgi && id == 42, kernel = e.ProviderGuid == DxgKrnl && id == 215;
        if (!dxgi && !kernel) return;
        var t = e.TimeStampRelativeMSec;
        var track = _tracks.GetOrAdd(e.ProcessID, _ => new Track());
        lock (track)
        {
            var q = dxgi ? track.Dxgi : track.Kernel;
            q.Enqueue(t);
            while (q.Count > 0 && t - q.Peek() > 10_000) q.Dequeue();
        }
    }

    /// pid → (fps over the last second, 1 % low over the last 10 s, average frame time in ms).
    public Dictionary<int, (double Fps, double Low1, double FrameTime)> Snapshot()
    {
        var now = _session == null ? 0 : _session.Source.SessionStartTime is var _ ? NowMs() : 0;
        var out_ = new Dictionary<int, (double, double, double)>();
        foreach (var (pid, track) in _tracks)
        {
            double[] times;
            lock (track) times = (track.Dxgi.Count > 0 ? track.Dxgi : track.Kernel).ToArray();
            if (times.Length < 2) { if (times.Length == 0) _tracks.TryRemove(pid, out _); continue; }
            var last = times[^1];
            if (now > 0 && now - last > 2000) { _tracks.TryRemove(pid, out _); continue; }
            var fps = times.Count(x => last - x < 1000);
            var gaps = new List<double>();
            for (var i = 1; i < times.Length; i++) gaps.Add(times[i] - times[i - 1]);
            gaps.Sort();
            var worst = gaps[(int)Math.Floor((gaps.Count - 1) * 0.99)];
            var avg = gaps.Average();
            out_[pid] = (fps, worst > 0 ? Math.Round(1000 / worst, 1) : 0, Math.Round(avg, 2));
        }
        return out_;
    }

    private double NowMs() => _session == null ? 0 : (DateTime.Now - _session.Source.SessionStartTime).TotalMilliseconds;

    public void Stop()
    {
        try { _session?.Dispose(); } catch (Exception) { }
        _session = null;
        _thread = null;
        _tracks.Clear();
    }

    public void Dispose() => Stop();
}
