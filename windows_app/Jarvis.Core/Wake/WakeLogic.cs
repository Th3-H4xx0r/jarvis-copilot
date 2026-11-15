using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Ui;

namespace Jarvis.Core.Wake;

/// Push to talk on one held key (port of the Mac's TalkKeyLogic): held for a beat before it
/// starts, so a Right Alt used for typing (AltGr) never talks; once talking, other keys don't stop
/// it, only letting go does.
public struct TalkKeyLogic
{
    public const double StartDelay = 0.15;

    public enum Action { None, Start, Send }
    private enum Phase { Idle, Waiting, Talking }

    private Phase _phase;
    private double _since;

    public bool Talking => _phase == Phase.Talking;
    public bool Waiting => _phase == Phase.Waiting;

    public Action KeyDown(double t)
    {
        if (_phase == Phase.Idle) { _phase = Phase.Waiting; _since = t; }
        return Action.None;
    }

    /// Called while waiting: held long enough, it starts.
    public Action Tick(double t)
    {
        if (_phase != Phase.Waiting || t - _since < StartDelay - 1e-6) return Action.None;
        _phase = Phase.Talking;
        return Action.Start;
    }

    /// Another key while waiting: it was a modifier for typing.
    public Action OtherKey()
    {
        if (_phase == Phase.Waiting) _phase = Phase.Idle;
        return Action.None;
    }

    public Action KeyUp(double t)
    {
        var talking = _phase == Phase.Talking;
        _phase = Phase.Idle;
        return talking ? Action.Send : Action.None;
    }
}

/// "Hey Jarvis" rate limits: a score over the threshold wakes it, at most once per 5 s and five
/// times a minute (a TV saying "Jarvis" over and over can't keep it busy).
public sealed class WakeGate
{
    public const double Threshold = 0.5;
    public const double MinInterval = 5;
    public const int PerMinute = 5;

    private readonly Queue<double> _recent = new();
    private double? _last;

    public bool Allow(double score, double nowSeconds)
    {
        if (score < Threshold) return false;
        if (_last is { } l && nowSeconds - l < MinInterval) return false;
        while (_recent.Count > 0 && nowSeconds - _recent.Peek() >= 60) _recent.Dequeue();
        if (_recent.Count >= PerMinute) return false;
        _recent.Enqueue(nowSeconds);
        _last = nowSeconds;
        return true;
    }
}

/// openWakeWord's feature plumbing: 80 ms audio chunks → mel frames (32 bins) → 76-frame windows
/// every 8 frames → 96-d embeddings → the last 16 embeddings feed the "hey_jarvis" model.
public sealed class OwwFeatures
{
    public const int ChunkSamples = 1280;
    public const int MelBins = 32;
    public const int MelWindow = 76;
    public const int MelStep = 8;
    public const int EmbeddingWindow = 16;
    public const int EmbeddingSize = 96;
    private const int KeepMel = MelWindow + 4 * MelStep;

    private readonly List<float[]> _mel = new();
    private readonly List<float[]> _emb = new();
    private int _melSinceWindow;
    private bool _firstWindow = true;

    /// openWakeWord's scaling of the melspectrogram model's output.
    public static float Transform(float raw) => raw / 10f + 2f;

    public void PushMel(float[,] mel)
    {
        var n = mel.GetLength(0);
        for (var i = 0; i < n; i++)
        {
            var row = new float[MelBins];
            for (var j = 0; j < MelBins && j < mel.GetLength(1); j++) row[j] = mel[i, j];
            _mel.Add(row);
            _melSinceWindow++;
        }
        if (_mel.Count > KeepMel)
        {
            _mel.RemoveRange(0, _mel.Count - KeepMel);
        }
    }

    /// The next 76×32 window, when 8 new frames have arrived since the last one (the first needs 76).
    public bool TryTakeMelWindow(out float[] window)
    {
        window = Array.Empty<float>();
        if (_mel.Count < MelWindow) return false;
        if (!_firstWindow && _melSinceWindow < MelStep) return false;
        _firstWindow = false;
        _melSinceWindow = 0;
        window = new float[MelWindow * MelBins];
        var start = _mel.Count - MelWindow;
        for (var i = 0; i < MelWindow; i++) Array.Copy(_mel[start + i], 0, window, i * MelBins, MelBins);
        return true;
    }

    public void PushEmbedding(float[] e96)
    {
        _emb.Add(e96);
        if (_emb.Count > EmbeddingWindow) _emb.RemoveAt(0);
    }

    public bool TryEmbeddingWindow(out float[] w)
    {
        w = Array.Empty<float>();
        if (_emb.Count < EmbeddingWindow) return false;
        w = new float[EmbeddingWindow * EmbeddingSize];
        for (var i = 0; i < EmbeddingWindow; i++) Array.Copy(_emb[i], 0, w, i * EmbeddingSize, Math.Min(EmbeddingSize, _emb[i].Length));
        return true;
    }

    public void Reset()
    {
        _mel.Clear();
        _emb.Clear();
        _melSinceWindow = 0;
        _firstWindow = true;
    }
}

/// Tell jc-client which display push to talk is held on, so Jarvis's "look at this" reads that
/// screen (desktop_client/jc_client/skills/ui.py note_talk_screen).
public static class TalkScreen
{
    public static JsonObject Message(RectI bounds, string name) => new()
    {
        ["type"] = "talk_screen",
        ["bounds"] = new JsonArray(bounds.Left, bounds.Top, bounds.Width, bounds.Height),
        ["name"] = name,
    };

    /// The monitor under the cursor, else the nearest.
    public static (string Name, RectI Bounds)? Pick(IReadOnlyList<(string Name, RectI Bounds)> monitors, PointD cursor)
    {
        if (monitors.Count == 0) return null;
        foreach (var m in monitors)
            if (cursor.X >= m.Bounds.Left && cursor.X < m.Bounds.Right && cursor.Y >= m.Bounds.Top && cursor.Y < m.Bounds.Bottom) return m;
        double Dist((string, RectI B) m) =>
            Math.Max(0, Math.Max(m.B.Left - cursor.X, cursor.X - m.B.Right)) + Math.Max(0, Math.Max(m.B.Top - cursor.Y, cursor.Y - m.B.Bottom));
        return monitors.OrderBy(m => Dist(m)).First();
    }
}

/// The screen glow's path: each half runs from the top centre around one side to the bottom
/// centre, with rounded corners, so two halves meet in the middle like the Mac's.
public static class EdgeGlowPath
{
    public static IReadOnlyList<PointD> Half(RectI screen, double corner, bool right)
    {
        double l = screen.Left, t = screen.Top, r = screen.Right, b = screen.Bottom;
        var cx = (l + r) / 2;
        var c = Math.Max(0, Math.Min(corner, Math.Min(screen.Width, screen.Height) / 2.0));
        var pts = new List<PointD> { new(cx, t) };
        void Arc(double ox, double oy, double fromDeg, double toDeg)
        {
            const int steps = 8;
            for (var i = 0; i <= steps; i++)
            {
                var a = (fromDeg + (toDeg - fromDeg) * i / steps) * Math.PI / 180;
                pts.Add(new PointD(ox + c * Math.Cos(a), oy + c * Math.Sin(a)));
            }
        }
        if (right)
        {
            pts.Add(new PointD(r - c, t));
            Arc(r - c, t + c, -90, 0);
            pts.Add(new PointD(r, b - c));
            Arc(r - c, b - c, 0, 90);
        }
        else
        {
            pts.Add(new PointD(l + c, t));
            Arc(l + c, t + c, -90, -180);
            pts.Add(new PointD(l, b - c));
            Arc(l + c, b - c, 180, 90);
        }
        pts.Add(new PointD(cx, b));
        return pts;
    }
}
