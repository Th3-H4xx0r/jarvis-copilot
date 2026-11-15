using System.Net.NetworkInformation;
using LibreHardwareMonitor.Hardware;

namespace JarvisSensors;

/// The PC's sensors through LibreHardwareMonitor (CPU, NVIDIA GPU, RAM, motherboard Super I/O,
/// storage), read on demand and mapped to PC Stats reading keys (webui/api/pc_stats_catalog.py).
/// Fans that read 0 and implausible temperatures (Super I/O channels with nothing on them) are
/// left out. Network comes from the adapters' own byte counters.
internal sealed class Sensors : IDisposable
{
    private readonly Computer _pc = new()
    {
        IsCpuEnabled = true, IsGpuEnabled = true, IsMemoryEnabled = true, IsMotherboardEnabled = true,
        IsStorageEnabled = true, IsControllerEnabled = false, IsNetworkEnabled = false, IsPsuEnabled = false,
    };
    private bool _open;
    private int _tick;
    private readonly Dictionary<string, double> _slow = new();
    private long _rx, _tx;
    private DateTime _netAt;

    public Dictionary<string, double> Read()
    {
        if (!_open) { _pc.Open(); _open = true; }
        var r = new Dictionary<string, double>();
        // CPU and GPU every second; memory, storage and the motherboard (slow bus reads) every 5 s.
        var slow = _tick++ % 5 == 0;
        if (slow) _slow.Clear();
        foreach (var hw in _pc.Hardware)
        {
            var isSlow = hw.HardwareType is HardwareType.Memory or HardwareType.Storage or HardwareType.Motherboard;
            if (isSlow && !slow) continue;
            Visit(hw, isSlow ? _slow : r);
        }
        foreach (var (k, v) in _slow) r[k] = v;
        Network(r);
        try
        {
            var sys = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\");
            if (sys.IsReady && sys.TotalSize > 0) r["disk.used"] = Math.Round(100.0 * (sys.TotalSize - sys.TotalFreeSpace) / sys.TotalSize, 1);
        }
        catch (IOException) { }
        return r;
    }

    private void Visit(IHardware hw, Dictionary<string, double> r)
    {
        hw.Update();
        switch (hw.HardwareType)
        {
            case HardwareType.Cpu: Cpu(hw, r); break;
            case HardwareType.GpuNvidia or HardwareType.GpuAmd or HardwareType.GpuIntel: Gpu(hw, r); break;
            case HardwareType.Memory: Memory(hw, r); break;
            case HardwareType.Storage: Storage(hw, r); break;
            case HardwareType.SuperIO: SuperIo(hw, r); break;
        }
        foreach (var sub in hw.SubHardware) Visit(sub, r);
    }

    private static float? Find(IHardware hw, SensorType type, params string[] names)
    {
        foreach (var name in names)
            if (hw.Sensors.FirstOrDefault(s => s.SensorType == type && s.Name == name && s.Value is not null) is { } s) return s.Value;
        return null;
    }

    private static void Cpu(IHardware hw, Dictionary<string, double> r)
    {
        if (Find(hw, SensorType.Load, "CPU Total") is { } load) r["cpu.load"] = Math.Round(load, 1);
        if (Find(hw, SensorType.Temperature, "CPU Package", "Core Max", "Core (Tctl/Tdie)") is { } t) r["cpu.temp"] = Math.Round(t, 1);
        if (Find(hw, SensorType.Power, "CPU Package", "Package") is { } p) r["cpu.power"] = Math.Round(p, 1);
        var clocks = hw.Sensors.Where(s => s.SensorType == SensorType.Clock && s.Name.Contains("Core") && s.Value > 100).Select(s => (double)s.Value!.Value).ToList();
        if (clocks.Count > 0) r["cpu.clock"] = Math.Round(clocks.Max());
    }

    private static void Gpu(IHardware hw, Dictionary<string, double> r)
    {
        if (r.ContainsKey("gpu.load")) return;   // the first (discrete) GPU wins
        if (Find(hw, SensorType.Load, "GPU Core", "D3D 3D") is { } load) r["gpu.load"] = Math.Round(load, 1);
        if (Find(hw, SensorType.Temperature, "GPU Core") is { } t) r["gpu.temp"] = Math.Round(t, 1);
        if (Find(hw, SensorType.Temperature, "GPU Hot Spot", "GPU Memory Junction") is { } hs) r["gpu.hotspot"] = Math.Round(hs, 1);
        if (Find(hw, SensorType.Clock, "GPU Core") is { } c) r["gpu.clock"] = Math.Round(c);
        if (Find(hw, SensorType.Clock, "GPU Memory") is { } mc) r["gpu.mem_clock"] = Math.Round(mc);
        if (Find(hw, SensorType.Power, "GPU Package", "GPU Power") is { } p) r["gpu.power"] = Math.Round(p, 1);
        if (Find(hw, SensorType.Fan, "GPU Fan", "GPU Fan 1") is { } f) r["gpu.fan"] = Math.Round(f);
        if (Find(hw, SensorType.SmallData, "GPU Memory Used") is { } used) r["gpu.vram_used"] = Math.Round(used / 1024.0, 2);
        if (Find(hw, SensorType.SmallData, "GPU Memory Total") is { } total) r["gpu.vram_total"] = Math.Round(total / 1024.0, 1);
    }

    private static void Memory(IHardware hw, Dictionary<string, double> r)
    {
        var id = hw.Identifier.ToString();
        if (id == "/ram")
        {
            if (Find(hw, SensorType.Data, "Memory Used") is { } used && Find(hw, SensorType.Data, "Memory Available") is { } avail)
            {
                r["ram.used"] = Math.Round(used, 2);
                r["ram.total"] = Math.Round(used + avail, 1);
            }
        }
        else if (id == "/vram")
        {
            if (Find(hw, SensorType.Data, "Memory Used") is { } commit) r["ram.commit"] = Math.Round(commit, 2);
        }
        else if (hw.Sensors.FirstOrDefault(s => s.SensorType == SensorType.Temperature && s.Name.StartsWith("DIMM")) is { Value: { } dimm } d)
            Temp(r, d.Name, dimm);
    }

    private static void Storage(IHardware hw, Dictionary<string, double> r)
    {
        if (Find(hw, SensorType.Temperature, "Composite Temperature", "Temperature") is { } t)
            Temp(r, hw.Sensors.Any(s => s.Name == "Composite Temperature") ? "NVMe" : hw.Name, t);
        if (Find(hw, SensorType.Throughput, "Read Rate") is { } rd) r["disk.read"] = Math.Round(r.GetValueOrDefault("disk.read") + rd / 1_048_576.0, 2);
        if (Find(hw, SensorType.Throughput, "Write Rate") is { } wr) r["disk.write"] = Math.Round(r.GetValueOrDefault("disk.write") + wr / 1_048_576.0, 2);
    }

    private static void SuperIo(IHardware hw, Dictionary<string, double> r)
    {
        foreach (var s in hw.Sensors)
        {
            if (s.Value is not { } v) continue;
            if (s.SensorType == SensorType.Fan && v > 100) r[Slug("fan", s.Name)] = Math.Round(v);
            else if (s.SensorType == SensorType.Temperature && v is > 15 and < 110 && !s.Name.Contains("CPU")) Temp(r, "Board " + s.Name, v);
        }
    }

    private static void Temp(Dictionary<string, double> r, string name, double v)
    {
        if (v is > 5 and < 125) r[Slug("temp", name)] = Math.Round(v, 1);
    }

    private void Network(Dictionary<string, double> r)
    {
        long rx = 0, tx = 0;
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            var st = nic.GetIPv4Statistics();
            rx += st.BytesReceived;
            tx += st.BytesSent;
        }
        var now = DateTime.UtcNow;
        var dt = (now - _netAt).TotalSeconds;
        if (_netAt != default && dt > 0.2)
        {
            r["net.down"] = Math.Round(Math.Max(0, rx - _rx) / dt / 1_048_576.0, 2);
            r["net.up"] = Math.Round(Math.Max(0, tx - _tx) / dt / 1_048_576.0, 2);
        }
        (_rx, _tx, _netAt) = (rx, tx, now);
    }

    /// "Fan #1" → "fan.fan_1" (the same rule as the app's ReadingKeys.Slug).
    public static string Slug(string family, string name)
    {
        var chars = name.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray();
        var slug = string.Join('_', new string(chars).Split('_', StringSplitOptions.RemoveEmptyEntries));
        if (slug.Length > 40) slug = slug[..40];
        return $"{family}.{(slug.Length == 0 ? "x" : slug)}";
    }

    public void Close()
    {
        if (_open) { _pc.Close(); _open = false; }
        _tick = 0;
        _slow.Clear();
    }

    public void Dispose() => Close();
}
