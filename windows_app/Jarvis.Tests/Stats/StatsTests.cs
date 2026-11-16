using System.Text.Json.Nodes;
using Jarvis.Core.Stats;

namespace Jarvis.Tests.Stats;

public class StatsTests
{
    private static StatsSample S(double t, params (string K, double V)[] r) =>
        new(t, r.ToDictionary(x => x.K, x => x.V), null);

    [Fact]
    public void PowerModel_EstimatesCpuFromLoad()
    {
        var (w, est) = PowerModel.Compute(new Dictionary<string, double> { [ReadingKeys.CpuLoad] = 50 }, new PowerSettings());
        Assert.Equal(13 + 68.25 * Math.Pow(0.5, 1.6), w[ReadingKeys.PowerCpu], 1);
        Assert.Contains(ReadingKeys.PowerCpu, est);
        Assert.False(w.ContainsKey(ReadingKeys.PowerGpu));   // no GPU reading at all: no GPU line
    }

    [Fact]
    public void PowerModel_UsesMeasuredWhenPresent()
    {
        var (w, est) = PowerModel.Compute(new Dictionary<string, double>
        {
            [ReadingKeys.CpuPower] = 63.5, [ReadingKeys.GpuPower] = 191, [ReadingKeys.GpuLoad] = 96,
        }, new PowerSettings());
        Assert.Equal(63.5, w[ReadingKeys.PowerCpu]);
        Assert.Equal(191, w[ReadingKeys.PowerGpu]);
        Assert.DoesNotContain(ReadingKeys.PowerCpu, est);
        Assert.DoesNotContain(ReadingKeys.PowerGpu, est);
        Assert.Contains(ReadingKeys.PowerTotal, est);
    }

    [Fact]
    public void PowerModel_TotalAppliesPsu()
    {
        var r = new Dictionary<string, double> { [ReadingKeys.CpuPower] = 100, [ReadingKeys.GpuPower] = 200 };
        var (w, _) = PowerModel.Compute(r, new PowerSettings(PsuEfficiency: 80));
        var parts = 100 + 200 + 5 + 0.05 + 0.2;
        Assert.Equal(Math.Round(parts / 0.8, 1), w[ReadingKeys.PowerTotal]);
    }

    [Fact]
    public void Sessions_StartStopSummary()
    {
        var t = new SessionTracker();
        for (var i = 0; i < 100; i++)
            Assert.Null(t.Update(S(1000 + i, (ReadingKeys.Fps, i == 0 ? 30 : 120), (ReadingKeys.PowerTotal, 360), (ReadingKeys.GpuTemp, 60 + i % 10)), "cod.exe"));
        var done = t.Update(S(1100, (ReadingKeys.Fps, 0)), null);
        Assert.NotNull(done);
        Assert.Equal("cod.exe", done!.Exe);
        Assert.Equal(1000, done.Start);
        Assert.Equal(1099, done.End);
        Assert.Equal(30, done.FpsLow1);
        Assert.Equal(69, done.GpuTempMax);
        Assert.Equal(360 * 99 / 3600.0, done.EnergyWh, 1);
        Assert.False(t.Active);
    }

    [Fact]
    public void Moments_GpuHotFor5sMarksOnce()
    {
        var m = new MomentDetector(new Thresholds(GpuTemp: 85));
        var found = new List<Moment>();
        for (var i = 0; i < 20; i++) found.AddRange(m.Update(S(i, (ReadingKeys.GpuTemp, 88)), false));
        Assert.Single(found);
        Assert.Equal("hot-gpu", found[0].Kind);
        Assert.Equal(0, found[0].T);
        found.AddRange(m.Update(S(21, (ReadingKeys.GpuTemp, 70)), false));
        for (var i = 22; i < 30; i++) found.AddRange(m.Update(S(i, (ReadingKeys.GpuTemp, 90)), false));
        Assert.Equal(2, found.Count);   // a new episode after it cooled
    }

    [Fact]
    public void Moments_FpsDropWhileInGame()
    {
        var m = new MomentDetector(new Thresholds(FpsDropPct: 40));
        var found = new List<Moment>();
        for (var i = 0; i < 20; i++) found.AddRange(m.Update(S(i, (ReadingKeys.Fps, 144)), true));
        for (var i = 20; i < 26; i++) found.AddRange(m.Update(S(i, (ReadingKeys.Fps, 40)), true));
        Assert.Single(found);
        Assert.Equal("fps-drop", found[0].Kind);
    }

    private static Dashboard Board(params Widget[] w) => new("x", "X", null, w, 1);
    private static Widget W(string id, int x, int y, int w, int h) => new(id, "number", x, y, w, h, new[] { "cpu.load" }, new WidgetStyle());

    [Fact]
    public void Dashboard_RoundTrip()
    {
        var json = JsonNode.Parse("""
            {"id":"overview","name":"Overview","auto":"game","rev":4,"widgets":[
              {"id":"gpu","kind":"hero","x":0,"y":0,"w":6,"h":4,"readings":["gpu.load"],
               "style":{"chart":"area","color":"#8FDCFF","warn":85,"window":600,"meta":["gpu.temp","gpu.clock"],"label":"GPU"}}]}
            """)!.AsObject();
        var d = Dashboard.Parse(json);
        Assert.Equal(4, d.Rev);
        Assert.Equal("game", d.Auto);
        var w = d.Widgets.Single();
        Assert.Equal(("hero", 6, 4), (w.Kind, w.W, w.H));
        Assert.Equal(new[] { "gpu.temp", "gpu.clock" }, w.Style.Meta);
        var back = d.ToJson();
        Assert.Equal("area", back["widgets"]![0]!["style"]!["chart"]!.GetValue<string>());
        Assert.Null(back["rev"]);
        Assert.Equal(d with { Rev = null }, Dashboard.Parse(back) with { Widgets = d.Widgets });
    }

    [Fact]
    public void Layout_AutoPlaceAndOverlap()
    {
        var d = Board(W("a", 0, 0, 6, 4), W("b", 6, 0, 6, 2));
        Assert.Equal((6, 2), DashboardLayout.AutoPlace(d, 3, 2));
        Assert.Equal((0, 4), DashboardLayout.AutoPlace(d, 12, 1));
        Assert.False(DashboardLayout.CanPlace(d, W("b", 5, 0, 6, 2)));
        Assert.True(DashboardLayout.CanPlace(d, W("b", 6, 1, 6, 2)));
        Assert.False(DashboardLayout.CanPlace(d, W("c", 10, 0, 3, 1)));   // off the grid
        Assert.Equal(4, DashboardLayout.Rows(d));
    }

    [Fact]
    public void UploadPolicy_LiveVsBatch()
    {
        Assert.Equal(TimeSpan.FromSeconds(1), UploadPolicy.NextDelay(true));
        Assert.Equal(TimeSpan.FromSeconds(10), UploadPolicy.NextDelay(false));
        var avg = UploadPolicy.Average(new[] { S(1, ("cpu.load", 10)), S(2, ("cpu.load", 30), ("gpu.load", 50)) });
        Assert.Equal(2, avg.T);
        Assert.Equal(20, avg.R["cpu.load"]);
        Assert.Equal(50, avg.R["gpu.load"]);
    }

    [Fact]
    public void Widget_UnavailableReading_ShowsReason()
    {
        var r = new Dictionary<string, double> { ["gpu.temp"] = 66.9, ["ram.used"] = 17.87, ["gpu.clock"] = 2880 };
        Assert.Equal("67", WidgetText.Value("gpu.temp", r, null));
        Assert.Equal("17.9", WidgetText.Value("ram.used", r, null));
        Assert.Equal("2880", WidgetText.Value("gpu.clock", r, null));
        Assert.Equal("unavailable", WidgetText.Value("fps", r, null));
        Assert.Equal("needs the sensor driver", WidgetText.Value("cpu.temp", r, null, driverOff: true));
        Assert.Equal("warn", WidgetText.Level(86, new WidgetStyle(Warn: 85, Crit: 95)));
        Assert.Equal("crit", WidgetText.Level(96, new WidgetStyle(Warn: 85, Crit: 95)));
    }

    [Fact]
    public void Slug_NamesFansAndTemps()
    {
        Assert.Equal("fan.fan_1", ReadingKeys.Slug("fan", "Fan #1"));
        Assert.Equal("temp.dimm_3", ReadingKeys.Slug("temp", "DIMM #3"));
    }
}

public class CollectorTests
{
    private static Dictionary<string, double> Raw => new() { ["cpu.load"] = 30, ["cpu.power"] = 70, ["gpu.load"] = 95, ["gpu.power"] = 185 };

    [Fact]
    public void Collector_StopsWhenIntegrationOff()
    {
        var c = new CollectorLogic(new PowerSettings(), new Thresholds()) { On = true };
        Assert.NotNull(c.Tick(100, Raw, null, null));
        c.On = false;
        Assert.Null(c.Tick(101, Raw, null, null));
        Assert.Null(c.DueUpload(200));   // nothing kept from before
    }

    [Fact]
    public void Collector_BatchesAs10sAverages_LiveSendsEverySecond()
    {
        var c = new CollectorLogic(new PowerSettings(), new Thresholds()) { On = true };
        for (var t = 100; t < 120; t++) c.Tick(t, Raw, (144, 120, 6.9), "cod.exe");
        var batch = c.DueUpload(120)!;
        Assert.Equal(2, batch.Samples.Count);                           // two 10-second points
        Assert.Equal(144, batch.Samples[0].R["fps"]);
        Assert.True(batch.Samples[0].R.ContainsKey("power.total"));
        Assert.Contains("power.total", batch.Estimated);
        Assert.Null(c.DueUpload(125));                                  // 10 s between batches
        c.Uploaded(live: true);
        c.Tick(126, Raw, null, null);
        Assert.Single(c.DueUpload(126)!.Samples);                       // live: each second as-is
    }

    [Fact]
    public void Collector_SessionEndsAndRidesTheNextUpload()
    {
        var c = new CollectorLogic(new PowerSettings(), new Thresholds()) { On = true };
        for (var t = 0; t < 30; t++) c.Tick(t, Raw, (120, 100, 8), "cod.exe");
        c.Tick(30, Raw, null, null);
        var batch = c.DueUpload(31)!;
        Assert.Single(batch.Sessions);
        Assert.Equal("cod.exe", batch.Sessions[0].Exe);
    }
}

public class ChartMathTests
{
    [Fact]
    public void Smooth_takes_a_centred_average_and_keeps_times()
    {
        var pts = new List<(double, double)> { (0, 0), (1, 0), (2, 100), (3, 0), (4, 0) };
        var s = Jarvis.Core.Stats.ChartMath.Smooth(pts);
        Assert.Equal(5, s.Count);
        Assert.Equal(new[] { 0.0, 1, 2, 3, 4 }, s.Select(p => p.T));
        Assert.Equal(20, s[2].V, 3);              // the spike is spread over 5 points
        Assert.True(s.Max(p => p.V) < 100);
    }

    [Fact]
    public void Range_is_0_to_100_for_percent()
    {
        Assert.Equal((0.0, 100.0), Jarvis.Core.Stats.ChartMath.Range("gpu.load", "%", new[] { 3.0, 99 }));
    }

    [Fact]
    public void Range_ignores_one_spike()
    {
        var values = Enumerable.Repeat(100.0, 99).Append(1000).ToList();   // fps ~100 with one 1000 spike
        var (min, max) = Jarvis.Core.Stats.ChartMath.Range("fps", "fps", values);
        Assert.Equal(0, min);
        Assert.InRange(max, 114, 116);
    }

    [Fact]
    public void Range_for_temperatures_starts_near_the_lowest()
    {
        var (min, max) = Jarvis.Core.Stats.ChartMath.Range("gpu.temp", "°C", new[] { 60.0, 65, 70 });
        Assert.Equal(50, min);
        Assert.True(max > 70);
    }
}


public class SessionSnapshotTests
{
    [Fact]
    public void Current_follows_the_game_and_Last_keeps_the_finished_one()
    {
        var t = new SessionTracker();
        var r = new Dictionary<string, double> { [ReadingKeys.Fps] = 100, [ReadingKeys.PowerTotal] = 360 };
        Assert.Null(t.Current);
        t.Update(new StatsSample(1000, r, "cod.exe"), "cod.exe");
        t.Update(new StatsSample(1010, r, "cod.exe"), "cod.exe");
        Assert.Equal("cod.exe", t.Current!.Exe);
        Assert.Equal(10, t.Current.End - t.Current.Start);
        Assert.Equal(1, t.Current.EnergyWh, 3);           // 360 W for 10 s
        t.Update(new StatsSample(1011, r, null), null);
        Assert.Null(t.Current);
        Assert.Equal("cod.exe", t.Last!.Exe);
    }
}
