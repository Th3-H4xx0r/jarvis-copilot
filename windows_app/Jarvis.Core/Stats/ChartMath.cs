namespace Jarvis.Core.Stats;

/// Chart maths: smoothing and a range a single spike can't flatten.
public static class ChartMath
{
    /// A centred moving average: about 5 points at 1 Hz, wider for long windows.
    public static List<(double T, double V)> Smooth(IReadOnlyList<(double T, double V)> pts)
    {
        if (pts.Count < 3) return pts.ToList();
        var half = Math.Max(2, pts.Count / 120);
        var out_ = new List<(double, double)>(pts.Count);
        for (var i = 0; i < pts.Count; i++)
        {
            int a = Math.Max(0, i - half), b = Math.Min(pts.Count - 1, i + half);
            double sum = 0;
            for (var j = a; j <= b; j++) sum += pts[j].V;
            out_.Add((pts[i].T, sum / (b - a + 1)));
        }
        return out_;
    }

    /// 0–100 for percentages; else a floor (0 for counts, rates and watts) to the 98th percentile × 1.15.
    public static (double Min, double Max) Range(string key, string unit, IEnumerable<double> values)
    {
        if (unit == "%") return (0, 100);
        var v = values.OrderBy(x => x).ToList();
        if (v.Count == 0) return (0, 1);
        var p98 = v[(int)Math.Floor((v.Count - 1) * 0.98)];
        var zeroBased = key.StartsWith("fps") || key.StartsWith("power") || key.StartsWith("net") || key.StartsWith("disk") || key == "frametime";
        var min = zeroBased ? 0 : Math.Floor(v[0] * 0.9 / 5) * 5;
        var max = Math.Max(min + 1, p98 * 1.15);
        return (min, max);
    }
}
