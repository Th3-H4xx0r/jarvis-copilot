namespace Jarvis.Core.Stats;

/// The thresholds that mark a moment (PC Stats settings warn_*).
public sealed record Thresholds(double GpuTemp = 85, double CpuTemp = 95, double PowerSpike = 1.3, double FpsDropPct = 40);

/// A marked moment for the history graphs (never a notification).
public sealed record Moment(string Id, double T, string Key, double Value, double Threshold, string Kind, double DurationS, string Label)
{
    public Dictionary<string, object> ToWire() => new()
    {
        ["id"] = Id, ["t"] = T, ["key"] = Key, ["value"] = Math.Round(Value, 1), ["threshold"] = Threshold,
        ["kind"] = Kind, ["duration_s"] = DurationS, ["label"] = Label,
    };
}

/// Marks a moment once per episode: a temperature over its threshold for 5 s, whole-PC watts
/// above `PowerSpike` × the last hour's average for 5 s, or the frame rate falling by
/// `FpsDropPct` % from its recent level for 3 s while a game runs.
public sealed class MomentDetector
{
    private const double Hold = 5, FpsHold = 3, Window = 3600;
    private readonly Thresholds _t;
    private readonly Dictionary<string, double> _overSince = new();
    private readonly HashSet<string> _marked = new();
    private readonly Queue<(double T, double W)> _power = new();
    private double _powerSum;
    private readonly Queue<(double T, double Fps)> _fps = new();

    public MomentDetector(Thresholds t) => _t = t;

    public IReadOnlyList<Moment> Update(StatsSample s, bool inGame)
    {
        var found = new List<Moment>();
        Check(s, "hot-gpu", ReadingKeys.GpuTemp, _t.GpuTemp, Hold, "GPU ran hot", found);
        Check(s, "hot-cpu", ReadingKeys.CpuTemp, _t.CpuTemp, Hold, "CPU ran hot", found);

        if (s.R.TryGetValue(ReadingKeys.PowerTotal, out var w))
        {
            var avg = _power.Count >= 60 ? _powerSum / _power.Count : double.NaN;
            _power.Enqueue((s.T, w));
            _powerSum += w;
            while (_power.Count > 0 && s.T - _power.Peek().T > Window) _powerSum -= _power.Dequeue().W;
            if (!double.IsNaN(avg)) Episode(s, "power-spike", ReadingKeys.PowerTotal, w, avg * _t.PowerSpike, w > avg * _t.PowerSpike,
                Hold, "Power spike", found);
        }

        if (inGame && s.R.TryGetValue(ReadingKeys.Fps, out var fps))
        {
            var recent = _fps.Count >= 10 ? _fps.Average(f => f.Fps) : double.NaN;
            var floor = recent * (1 - _t.FpsDropPct / 100);
            var dropping = !double.IsNaN(recent) && fps < floor;
            if (!dropping) { _fps.Enqueue((s.T, fps)); while (_fps.Count > 0 && s.T - _fps.Peek().T > 30) _fps.Dequeue(); }
            Episode(s, "fps-drop", ReadingKeys.Fps, fps, double.IsNaN(floor) ? 0 : Math.Round(floor, 1), dropping, FpsHold, "Frame rate dropped", found);
        }
        else _fps.Clear();
        return found;
    }

    private void Check(StatsSample s, string kind, string key, double threshold, double hold, string label, List<Moment> found)
    {
        if (s.R.TryGetValue(key, out var v)) Episode(s, kind, key, v, threshold, v >= threshold, hold, label, found);
    }

    private void Episode(StatsSample s, string kind, string key, double value, double threshold, bool over, double hold, string label, List<Moment> found)
    {
        if (!over) { _overSince.Remove(kind); _marked.Remove(kind); return; }
        if (!_overSince.TryGetValue(kind, out var since)) { _overSince[kind] = s.T; return; }
        if (_marked.Contains(kind) || s.T - since < hold) return;
        _marked.Add(kind);
        found.Add(new Moment($"{(long)since}-{kind}", since, key, value, threshold, kind, s.T - since, label));
    }
}
