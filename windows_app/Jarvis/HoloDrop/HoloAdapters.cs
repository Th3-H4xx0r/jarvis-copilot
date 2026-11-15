using System.Collections.Specialized;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Platform;
using NAudio.Wave;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

namespace Jarvis.HoloDrop;

/// Open (ShellExecute) and copy (the clipboard: an image as a bitmap plus its file, text, a link,
/// or a file drop list). Runs on the Dispatcher (the clipboard needs STA).
public sealed class HoloReceiver : IHoloReceiver
{
    public bool Open(string pathOrUrl)
    {
        try
        {
            Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }

    /// The clipboard needs the STA UI thread; landings can arrive on any thread.
    public bool Copy(HoloDropRecord drop, string? localFile) =>
        Application.Current.Dispatcher.CheckAccess() ? CopyNow(drop, localFile) : Application.Current.Dispatcher.Invoke(() => CopyNow(drop, localFile));

    private static bool CopyNow(HoloDropRecord drop, string? localFile)
    {
        try
        {
            var data = new DataObject();
            switch (drop.Kind)
            {
                case HoloKind.Text:
                    data.SetText(drop.Text);
                    break;
                case HoloKind.Link:
                    data.SetText(drop.Url);
                    break;
                default:
                    if (localFile == null) return false;
                    if (drop.Kind == HoloKind.Image)
                    {
                        var img = new BitmapImage();
                        img.BeginInit();
                        img.UriSource = new Uri(localFile);
                        img.CacheOption = BitmapCacheOption.OnLoad;
                        img.EndInit();
                        img.Freeze();
                        data.SetImage(img);
                    }
                    data.SetFileDropList(new StringCollection { localFile });
                    break;
            }
            Clipboard.SetDataObject(data, copy: true);
            return true;
        }
        catch (Exception e) when (e is COMException or NotSupportedException or System.IO.IOException or ExternalException) { return false; }
    }
}

/// The inaudible chirp (48 kHz float samples from HoloBeaconCode) and the faint full-screen flash
/// on click-through windows, for the phone's "hear it" / "look at it" locate.
public sealed class HoloBeacons : IHoloBeacons
{
    private WaveOutEvent? _out;
    private readonly List<FlashWindow> _flash = new();
    private CancellationTokenSource? _cts;

    public void Chirp(string nonce)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            StopChirp();
            var samples = HoloBeaconCode.ChirpSamples(nonce, 48000);
            var provider = new BufferedWaveProvider(WaveFormat.CreateIeeeFloatWaveFormat(48000, 1)) { BufferLength = samples.Length * 4 + 4096, ReadFully = false };
            var bytes = new byte[samples.Length * 4];
            System.Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
            provider.AddSamples(bytes, 0, bytes.Length);
            _out = new WaveOutEvent();
            _out.Init(provider);
            _out.PlaybackStopped += (_, _) => StopChirp();
            _out.Play();
        });
    }

    private void StopChirp()
    {
        _out?.Dispose();
        _out = null;
    }

    public void Flash(string nonce)
    {
        Application.Current.Dispatcher.BeginInvoke(async () =>
        {
            StopFlash();
            _cts = new CancellationTokenSource();
            var ct = _cts.Token;
            foreach (var m in Monitors.All()) { var w = new FlashWindow(m); _flash.Add(w); }
            var frames = HoloBeaconCode.FlashFrames(nonce);
            var starts = HoloBeaconCode.FlashFrameStarts(frames.Count);
            var clock = Stopwatch.StartNew();
            for (var i = 0; i < frames.Count && !ct.IsCancellationRequested; i++)
            {
                var wait = starts[i] - clock.Elapsed;
                if (wait > TimeSpan.Zero) await Task.Delay(wait, CancellationToken.None);
                foreach (var w in _flash) w.Lit(frames[i]);
            }
            StopFlash();
        });
    }

    private void StopFlash()
    {
        _cts?.Cancel();
        foreach (var w in _flash) w.Close();
        _flash.Clear();
    }

    public void Stop() => Application.Current.Dispatcher.BeginInvoke(() => { StopChirp(); StopFlash(); });

    private sealed class FlashWindow : Ui.NoActivateWindow
    {
        public FlashWindow(Monitors.Info m)
        {
            Background = Ui.Th.B("JcAccent");
            Opacity = 0;
            IsHitTestVisible = false;
            SourceInitialized += (_, _) =>
            {
                var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
                var ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
                Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(ex | Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED));
                Monitors.Place(hwnd, m.Bounds);
            };
            Show();
        }

        public void Lit(bool on) => Opacity = on ? HoloBeaconCode.FlashAlpha : 0;
    }
}

/// The primary monitor and the outlines of its windows, for the sender's map of where to drop.
public sealed class HoloScreenReport : IHoloScreenReport
{
    [ThreadStatic] private static List<(RectI, string)>? _windows;

    public HoloScreen Current()
    {
        var m = Monitors.Primary();
        var bounds = m?.Bounds ?? new RectI(0, 0, 1920, 1080);
        var scale = m != null ? Monitors.Scale(m.Handle) : 1;
        _windows = new List<(RectI, string)>();
        Enumerate();
        var outlines = HoloGeometry.Outlines(_windows, bounds);
        _windows = null;
        return new HoloScreen(bounds.Width / scale, bounds.Height / scale, scale, outlines);
    }

    private static unsafe void Enumerate() => Native.EnumWindows(&Visit, IntPtr.Zero);

    [UnmanagedCallersOnly]
    private static int Visit(IntPtr hwnd, IntPtr data)
    {
        if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd) || Native.GetWindow(hwnd, Native.GW_OWNER) != IntPtr.Zero) return 1;
        var buf = new char[256];
        var n = Native.GetWindowText(hwnd, buf, buf.Length);
        if (n == 0 || !Native.GetWindowRect(hwnd, out var r)) return 1;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId) return 1;
        string app;
        try { app = Process.GetProcessById((int)pid).ProcessName; }
        catch (ArgumentException) { return 1; }
        _windows?.Add((new RectI(r.Left, r.Top, r.Right, r.Bottom), app));
        return _windows?.Count >= 40 ? 0 : 1;
    }
}

/// The Bluetooth beacon the iPhone ranks by signal: the Holo service UUID plus manufacturer data
/// (company 0xFFFF, "HD" + FNV-1a of the device id). Windows forbids a LocalName, so the phone
/// matches on the manufacturer data (cross-plan (e)).
public sealed class HoloBleBeacon : IHoloBleBeacon
{
    private BluetoothLEAdvertisementPublisher? _pub;

    public void Start(string deviceId)
    {
        Stop();
        try
        {
            var ad = new BluetoothLEAdvertisement();
            ad.ServiceUuids.Add(HoloBle.Service);
            var writer = new DataWriter();
            writer.WriteBytes(HoloBle.ManufacturerPayload(deviceId));
            ad.ManufacturerData.Add(new BluetoothLEManufacturerData(HoloBle.CompanyId, writer.DetachBuffer()));
            _pub = new BluetoothLEAdvertisementPublisher(ad);
            _pub.Start();
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException or ArgumentException)
        {
            _pub = null;   // no Bluetooth radio, or it's off: the phone still finds the PC through the server
        }
    }

    public void Stop()
    {
        try { _pub?.Stop(); } catch (COMException) { }
        _pub = null;
    }
}

/// Whether the firewall rule exists: `netsh advfirewall firewall show rule name="Jarvis Holo Drop"`
/// exits 0. Read-only, no elevation needed.
public sealed class HoloFirewallProbe : IHoloFirewall
{
    public bool RuleExists()
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{HoloFirewall.RuleName}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
            };
            using var p = Process.Start(psi);
            if (p == null) return false;
            p.StandardOutput.ReadToEnd();
            return p.WaitForExit(5000) && p.ExitCode == 0;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
}
