namespace Jarvis.Core.Stats;

/// One second of the PC's readings (the server's /api/pc-stats keys, `Readings.All`), plus the game
/// in front if one is running.
public sealed record StatsSample(double T, IReadOnlyDictionary<string, double> R, string? Game);

/// The reading keys the server knows (webui/api/pc_stats_catalog.py READINGS). Named fans and
/// temperatures go as `fan.<slug>` / `temp.<slug>`.
public static class ReadingKeys
{
    public const string CpuLoad = "cpu.load", CpuTemp = "cpu.temp", CpuClock = "cpu.clock", CpuPower = "cpu.power";
    public const string GpuLoad = "gpu.load", GpuTemp = "gpu.temp", GpuHotspot = "gpu.hotspot", GpuClock = "gpu.clock",
        GpuMemClock = "gpu.mem_clock", GpuPower = "gpu.power", GpuFan = "gpu.fan", GpuVramUsed = "gpu.vram_used",
        GpuVramTotal = "gpu.vram_total";
    public const string Fps = "fps", FpsLow1 = "fps.low1", FrameTime = "frametime";
    public const string RamUsed = "ram.used", RamTotal = "ram.total", RamCommit = "ram.commit";
    public const string DiskUsed = "disk.used", DiskRead = "disk.read", DiskWrite = "disk.write";
    public const string NetDown = "net.down", NetUp = "net.up";
    public const string PowerCpu = "power.cpu", PowerGpu = "power.gpu", PowerRam = "power.ram", PowerDisk = "power.disk",
        PowerNet = "power.net", PowerTotal = "power.total";

    /// "Fan #1" → "fan.fan_1"; "DIMM #3" → "temp.dimm_3".
    public static string Slug(string family, string name)
    {
        var chars = name.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray();
        var slug = string.Join('_', new string(chars).Split('_', StringSplitOptions.RemoveEmptyEntries));
        if (slug.Length > 40) slug = slug[..40];
        return $"{family}.{(slug.Length == 0 ? "x" : slug)}";
    }
}
