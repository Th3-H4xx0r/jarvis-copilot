namespace Jarvis.Core.Stats;

/// The settings the power model uses (PC Stats settings: psu_efficiency %, cpu_tdp, gpu_tdp; 0 =
/// the default).
public sealed record PowerSettings(double PsuEfficiency = 90, double CpuTdp = 0, double GpuTdp = 0);

/// Whole-PC watts, WattSeal's model reimplemented (its code is GPL; the formulas are facts):
/// measured CPU/GPU power when the sensors give it, otherwise `idle + (max − idle)·u^1.6` from
/// the TDP; RAM 5 W, SSD 0.05 W + 0.015 W per MB/s, network 0.2 W + 0.01 W per MB/s (≤ 3 W); the
/// parts' sum ÷ PSU efficiency is what the PC draws. Fans, motherboard and monitors aren't
/// counted, so the total is labelled "PC (est.)".
public static class PowerModel
{
    public const double DefaultCpuTdp = 65, DefaultGpuTdp = 200, RamWatts = 5;

    public static (Dictionary<string, double> Watts, HashSet<string> Estimated) Compute(
        IReadOnlyDictionary<string, double> r, PowerSettings s)
    {
        var watts = new Dictionary<string, double>();
        var estimated = new HashSet<string> { ReadingKeys.PowerRam, ReadingKeys.PowerDisk, ReadingKeys.PowerNet, ReadingKeys.PowerTotal };

        if (r.TryGetValue(ReadingKeys.CpuPower, out var cpu) && cpu > 0) watts[ReadingKeys.PowerCpu] = cpu;
        else
        {
            var tdp = s.CpuTdp > 0 ? s.CpuTdp : DefaultCpuTdp;
            var u = Load(r, ReadingKeys.CpuLoad);
            watts[ReadingKeys.PowerCpu] = 0.2 * tdp + (1.25 * tdp - 0.2 * tdp) * Math.Pow(u, 1.6);
            estimated.Add(ReadingKeys.PowerCpu);
        }

        if (r.TryGetValue(ReadingKeys.GpuPower, out var gpu) && gpu > 0) watts[ReadingKeys.PowerGpu] = gpu;
        else if (r.ContainsKey(ReadingKeys.GpuLoad))
        {
            var tdp = s.GpuTdp > 0 ? s.GpuTdp : DefaultGpuTdp;
            var idle = 0.1 * tdp;
            watts[ReadingKeys.PowerGpu] = idle + (tdp - idle) * Math.Pow(Load(r, ReadingKeys.GpuLoad), 1.6);
            estimated.Add(ReadingKeys.PowerGpu);
        }

        watts[ReadingKeys.PowerRam] = RamWatts;
        var mbps = Get(r, ReadingKeys.DiskRead) + Get(r, ReadingKeys.DiskWrite);
        watts[ReadingKeys.PowerDisk] = 0.05 + 0.015 * mbps;
        var net = Get(r, ReadingKeys.NetDown) + Get(r, ReadingKeys.NetUp);
        watts[ReadingKeys.PowerNet] = Math.Min(3, 0.2 + 0.01 * net);

        var efficiency = Math.Clamp(s.PsuEfficiency <= 0 ? 90 : s.PsuEfficiency, 50, 100) / 100;
        watts[ReadingKeys.PowerTotal] = watts.Values.Sum() / efficiency;
        foreach (var k in watts.Keys.ToList()) watts[k] = Math.Round(watts[k], 1);
        return (watts, estimated);
    }

    private static double Get(IReadOnlyDictionary<string, double> r, string key) => r.TryGetValue(key, out var v) ? Math.Max(0, v) : 0;

    private static double Load(IReadOnlyDictionary<string, double> r, string key) => Math.Clamp(Get(r, key) / 100, 0, 1);
}
