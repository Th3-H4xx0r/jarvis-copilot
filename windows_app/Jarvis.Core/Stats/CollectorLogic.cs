namespace Jarvis.Core.Stats;

/// One upload's worth: the samples (every second while live, else one 10-second average), the
/// estimated keys, finished sessions and new moments.
public sealed record UploadBatch(IReadOnlyList<StatsSample> Samples, IReadOnlySet<string> Estimated,
    IReadOnlyList<GameSession> Sessions, IReadOnlyList<Moment> Moments);

/// The collector's decisions, free of Windows: while the pc-stats integration is on, each
/// second's raw readings (+ the game's frame timing) become a sample with the power model's
/// watts, feed the session tracker and moment detector, and queue for upload — every second
/// while someone watches live (the server says so), else as 10-second averages. Off: nothing
/// is kept, sent or shown.
public sealed class CollectorLogic
{
    private readonly List<StatsSample> _pending = new();
    private readonly List<GameSession> _sessions = new();
    private readonly List<Moment> _moments = new();
    private HashSet<string> _estimated = new();
    private SessionTracker _tracker = new();
    private MomentDetector _detector;
    private double _lastUpload = double.NegativeInfinity;
    private bool _on;

    public CollectorLogic(PowerSettings power, Thresholds thresholds)
    {
        Power = power;
        Thresholds = thresholds;
        _detector = new MomentDetector(thresholds);
    }

    public PowerSettings Power { get; set; }
    public Thresholds Thresholds { get; private set; }
    public bool Live { get; private set; }

    /// The game being played so far, and the last one that ended (for the dashboard's session tile).
    public GameSession? CurrentSession => _tracker.Current;
    public GameSession? LastSession => _tracker.Last;

    public bool On
    {
        get => _on;
        set
        {
            if (_on == value) return;
            _on = value;
            if (!value) Reset();
        }
    }

    public void SetThresholds(Thresholds t)
    {
        if (t == Thresholds) return;
        Thresholds = t;
        _detector = new MomentDetector(t);
    }

    /// The sample for this second (null while off).
    public StatsSample? Tick(double t, IReadOnlyDictionary<string, double> raw, (double Fps, double Low1, double FrameTime)? frames,
        string? gameExe, bool throttling = false)
    {
        if (!_on) return null;
        var r = new Dictionary<string, double>(raw);
        if (gameExe != null && frames is { } f)
        {
            r[ReadingKeys.Fps] = f.Fps;
            r[ReadingKeys.FpsLow1] = f.Low1;
            r[ReadingKeys.FrameTime] = f.FrameTime;
        }
        var (watts, estimated) = PowerModel.Compute(r, Power);
        foreach (var (k, v) in watts) r[k] = v;
        _estimated = estimated;
        var sample = new StatsSample(t, r, gameExe);
        if (_tracker.Update(sample, gameExe, throttling) is { } done) _sessions.Add(done);
        _moments.AddRange(_detector.Update(sample, gameExe != null));
        _pending.Add(sample);
        if (_pending.Count > 600) _pending.RemoveRange(0, _pending.Count - 600);   // offline: keep the last 10 minutes
        return sample;
    }

    public IReadOnlySet<string> Estimated => _estimated;

    /// What to upload now, or null if it isn't time yet (or nothing's queued, or off).
    public UploadBatch? DueUpload(double now)
    {
        if (!_on || _pending.Count == 0 || now - _lastUpload < UploadPolicy.NextDelay(Live).TotalSeconds) return null;
        IReadOnlyList<StatsSample> samples = Live ? _pending.ToList() : Chunks(_pending);
        var batch = new UploadBatch(samples, new HashSet<string>(_estimated), _sessions.ToList(), _moments.ToList());
        _pending.Clear();
        _sessions.Clear();
        _moments.Clear();
        _lastUpload = now;
        return batch;
    }

    /// The server's reply to an upload: whether someone is watching live.
    public void Uploaded(bool live) => Live = live;

    /// An upload failed: put the batch back to try again with the next one.
    public void Requeue(UploadBatch b)
    {
        if (!_on) return;
        _pending.InsertRange(0, b.Samples);
        _sessions.InsertRange(0, b.Sessions);
        _moments.InsertRange(0, b.Moments);
        _lastUpload = double.NegativeInfinity;
    }

    private static List<StatsSample> Chunks(List<StatsSample> s)
    {
        var out_ = new List<StatsSample>();
        foreach (var g in s.GroupBy(x => Math.Floor(x.T / 10))) out_.Add(UploadPolicy.Average(g.ToList()));
        return out_;
    }

    private void Reset()
    {
        _pending.Clear();
        _sessions.Clear();
        _moments.Clear();
        _tracker = new SessionTracker();
        _detector = new MomentDetector(Thresholds);
        _lastUpload = double.NegativeInfinity;
        Live = false;
    }
}
