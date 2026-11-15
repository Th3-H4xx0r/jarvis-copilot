namespace Jarvis.Core.Ui;

public readonly record struct PointD(double X, double Y);

public enum JcLoaderStyle { Trace, Draw }

/// The Jarvis loader's geometry (port of ios_app/.../UI/JcLoader.swift): two identical elliptical
/// rings crossing in an X on a 24×24 grid (centre 12,12, rx 9.6, ry 4.2, tilted −38° / +38°).
/// Rings are flattened to polylines evenly spaced by arc length, so trims match the Swift
/// `trimmedPath` and the web's pathLength dashes.
public static class JcLoaderGeometry
{
    public static JcLoaderStyle Default = JcLoaderStyle.Trace;

    public const double TraceSegment = 0.26;
    public const double FaintOpacity = 0.22;

    public static double Period(JcLoaderStyle s) => s == JcLoaderStyle.Trace ? 1.5 : 2.6;

    private static readonly Dictionary<(double, int), IReadOnlyList<PointD>> RingCache = new();

    /// The ring rotated by `degrees` about (12,12), y down, starting at the left end and running
    /// left → bottom → right → top. `samples` points at i/samples of the length (closed: the
    /// last point joins back to the first).
    public static IReadOnlyList<PointD> Ring(double degrees, int samples = 96)
    {
        lock (RingCache)
        {
            if (RingCache.TryGetValue((degrees, samples), out var hit)) return hit;
        }
        const double cx = 12, cy = 12, rx = 9.6, ry = 4.2, k = 0.5522847498;
        var curves = new (PointD P0, PointD C1, PointD C2, PointD P3)[]
        {
            (new(cx - rx, cy), new(cx - rx, cy + k * ry), new(cx - k * rx, cy + ry), new(cx, cy + ry)),
            (new(cx, cy + ry), new(cx + k * rx, cy + ry), new(cx + rx, cy + k * ry), new(cx + rx, cy)),
            (new(cx + rx, cy), new(cx + rx, cy - k * ry), new(cx + k * rx, cy - ry), new(cx, cy - ry)),
            (new(cx, cy - ry), new(cx - k * rx, cy - ry), new(cx - rx, cy - k * ry), new(cx - rx, cy)),
        };
        // Dense polyline, then resample by arc length.
        const int steps = 256;
        var dense = new List<PointD> { curves[0].P0 };
        foreach (var c in curves)
        {
            for (var i = 1; i <= steps; i++) dense.Add(Bezier(c, i / (double)steps));
        }
        var cum = new double[dense.Count];
        for (var i = 1; i < dense.Count; i++) cum[i] = cum[i - 1] + Dist(dense[i - 1], dense[i]);
        var total = cum[^1];
        var output = new List<PointD>(samples);
        var j = 1;
        for (var s = 0; s < samples; s++)
        {
            var target = total * s / samples;
            while (j < cum.Length - 1 && cum[j] < target) j++;
            var seg = cum[j] - cum[j - 1];
            var f = seg <= 0 ? 0 : (target - cum[j - 1]) / seg;
            output.Add(Rotate(Lerp(dense[j - 1], dense[j], Math.Clamp(f, 0, 1)), degrees));
        }
        lock (RingCache) RingCache[(degrees, samples)] = output;
        return output;
    }

    private static PointD Bezier((PointD P0, PointD C1, PointD C2, PointD P3) c, double t)
    {
        var u = 1 - t;
        double a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t;
        return new(a * c.P0.X + b * c.C1.X + d * c.C2.X + e * c.P3.X, a * c.P0.Y + b * c.C1.Y + d * c.C2.Y + e * c.P3.Y);
    }

    private static PointD Rotate(PointD p, double degrees)
    {
        var r = degrees * Math.PI / 180;
        double dx = p.X - 12, dy = p.Y - 12, cos = Math.Cos(r), sin = Math.Sin(r);
        return new(12 + dx * cos - dy * sin, 12 + dx * sin + dy * cos);
    }

    private static double Dist(PointD a, PointD b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    private static PointD Lerp(PointD a, PointD b, double f) => new(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f);

    /// The part of the closed `ring` from `start` covering `length` (fractions of its length),
    /// as one polyline, or two when it wraps across the start point.
    public static IReadOnlyList<IReadOnlyList<PointD>> Segment(IReadOnlyList<PointD> ring, double start, double length)
    {
        var s = start - Math.Floor(start);
        var e = s + length;
        if (e <= 1) return new[] { Trim(ring, s, e) };
        return new[] { Trim(ring, s, 1), Trim(ring, 0, e - 1) };
    }

    /// Sub-polyline between fractions a ≤ b of the closed ring's length.
    public static IReadOnlyList<PointD> Trim(IReadOnlyList<PointD> ring, double a, double b)
    {
        var n = ring.Count;
        var cum = new double[n + 1];
        for (var i = 1; i <= n; i++) cum[i] = cum[i - 1] + Dist(ring[i - 1], ring[i % n]);
        var total = cum[n];
        double from = a * total, to = b * total;
        PointD At(double d)
        {
            var i = 1;
            while (i < n && cum[i] < d) i++;
            var seg = cum[i] - cum[i - 1];
            var f = seg <= 0 ? 0 : (d - cum[i - 1]) / seg;
            return Lerp(ring[i - 1], ring[i % n], Math.Clamp(f, 0, 1));
        }
        var pts = new List<PointD> { At(from) };
        for (var i = 1; i < n; i++)
        {
            if (cum[i] > from && cum[i] < to) pts.Add(ring[i]);
        }
        pts.Add(At(to));
        return pts;
    }

    /// 1.6 on the 24 grid, never thinner than 1.2.
    public static double StrokeWidth(double size) => Math.Max(1.2, size / 24 * 1.6);

    /// The Draw style's visible (from, to) at loop position `u`, or null while hidden.
    public static (double From, double To)? DrawTrim(double u, double start, double full, double hold)
    {
        if (u < start) return null;
        if (u < full) return (0, Ease((u - start) / (full - start)));
        if (u < hold) return (0, 1);
        return (Ease((u - hold) / (1 - hold)), 1);
    }

    private static double Ease(double x) => CubicBezier(x, 0.65, 0, 0.35, 1);

    /// CSS cubic-bezier(x1, y1, x2, y2) at progress x (bisection, 24 steps).
    public static double CubicBezier(double x, double x1, double y1, double x2, double y2)
    {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        static double Bez(double t, double a, double b)
        {
            var u = 1 - t;
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
        }
        double lo = 0, hi = 1, t = x;
        for (var i = 0; i < 24; i++)
        {
            t = (lo + hi) / 2;
            if (Bez(t, x1, x2) < x) lo = t; else hi = t;
        }
        return Bez(t, y1, y2);
    }

    /// One frame's polylines (in `size` units) and their opacity.
    public static IReadOnlyList<(IReadOnlyList<PointD> Points, double Opacity)> Frame(JcLoaderStyle s, double size, double phase)
    {
        var scale = size / 24;
        IReadOnlyList<PointD> Scaled(IReadOnlyList<PointD> pts) => pts.Select(p => new PointD(p.X * scale, p.Y * scale)).ToList();
        IReadOnlyList<PointD> Closed(IReadOnlyList<PointD> ring) => Scaled(ring.Append(ring[0]).ToList());
        var a = Ring(-38);
        var b = Ring(38);
        var frame = new List<(IReadOnlyList<PointD>, double)>();
        if (s == JcLoaderStyle.Trace)
        {
            frame.Add((Closed(a), FaintOpacity));
            frame.Add((Closed(b), FaintOpacity));
            foreach (var seg in Segment(a, phase, TraceSegment)) frame.Add((Scaled(seg), 1.0));
            foreach (var seg in Segment(b, 1 - phase, TraceSegment)) frame.Add((Scaled(seg), 1.0));
            return frame;
        }
        if (DrawTrim(phase, 0, 0.42, 0.60) is { } ta && ta.To > ta.From) frame.Add((Scaled(Trim(a, ta.From, ta.To)), 1.0));
        if (DrawTrim(phase, 0.12, 0.50, 0.66) is { } tb && tb.To > tb.From) frame.Add((Scaled(Trim(b, tb.From, tb.To)), 1.0));
        return frame;
    }
}
