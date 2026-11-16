using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Http;
using Jarvis.Core.Remote;
using Jarvis.Core.State;
using Jarvis.Platform;
using Microsoft.Win32;

namespace Jarvis.Remote;

/// Remote Desktop on this PC (docs/superpowers/specs/2026-11-15-remote-desktop-design.md): tells the
/// server whether RDP is ready and whether someone is using the PC (every 30 s), keeps his Microsoft
/// account password for RDP (DPAPI, its own file beside the Unlock PIN), and runs the setup via
/// AdminRunner (Face ID on his iPhone, then UAC).
public sealed class RemoteDesktop : IDisposable
{
    private static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis");
    internal static readonly string SecretPath = Path.Combine(Dir, "rdp.dat");

    private readonly ApiClient _api;
    private readonly AppState _state;
    private readonly AdminRunner _admin;
    private readonly Action<string> _log = FileLog.For("rdp");
    private readonly Timer _timer;
    private bool _locked, _off;
    private string? _upn, _tailscaleIp;
    private (DateTime At, bool Scoped) _firewall;

    public RemoteDesktop(ApiClient api, AppState state, AdminRunner admin)
    {
        _api = api;
        _state = state;
        _admin = admin;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        _timer = new Timer(_ => _ = PostAsync(), null, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30));
    }

    public event Action? Changed;

    public static bool IsPro => !Edition.Equals("Core", StringComparison.OrdinalIgnoreCase) && !Edition.StartsWith("Core", StringComparison.OrdinalIgnoreCase);

    /// "Core" (Home), "Professional", "Enterprise", "Education", …
    public static string Edition =>
        Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")?.GetValue("EditionID") as string ?? "";

    public static string ProductName =>
        Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")?.GetValue("ProductName") as string ?? "Windows";

    public static bool RdpEnabled =>
        Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Terminal Server")?.GetValue("fDenyTSConnections") is int deny && deny == 0;

    public static bool HelloOnlyOff =>
        Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device")?.GetValue("DevicePasswordLessBuildVersion") is not int v || v == 0;

    public bool HasPassword => File.Exists(SecretPath);

    /// Only our Tailscale-scoped rule exists (checked through the firewall's COM API, at most every 5 min).
    public bool FirewallScoped
    {
        get
        {
            if (DateTime.UtcNow - _firewall.At < TimeSpan.FromMinutes(5)) return _firewall.Scoped;
            var scoped = false;
            try
            {
                dynamic policy = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2")!)!;
                foreach (dynamic rule in policy.Rules)
                    if ((string)rule.Name == RdpSetup.RuleName && (string)rule.RemoteAddresses == RdpSetup.TailscaleCidr) scoped = true;
            }
            catch (COMException) { }
            _firewall = (DateTime.UtcNow, scoped);
            return scoped;
        }
    }

    public string Username => RdpSetup.Username(_upn ??= Run("whoami", "/upn"), Environment.UserName);

    public void SavePassword(string password)
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllBytes(SecretPath, Unlock.Dpapi.Protect(Encoding.UTF8.GetBytes(password)));
        Changed?.Invoke();
        _ = PostAsync();
    }

    public void ForgetPassword()
    {
        if (File.Exists(SecretPath)) File.Delete(SecretPath);
        Changed?.Invoke();
        _ = PostAsync();
    }

    /// The saved password, decrypted (only for an approved session's release).
    internal static string? ReadPassword() =>
        File.Exists(SecretPath) ? Encoding.UTF8.GetString(Unlock.Dpapi.Unprotect(File.ReadAllBytes(SecretPath))) : null;

    /// Face ID on his iPhone, then UAC: switches RDP on, Tailscale-only (also the Repair).
    public async Task<AdminResult> SetUpAsync(int idleMinutes = 30)
    {
        var r = await _admin.RunAsync(RdpSetup.PowerShellCommand(RdpSetup.SetupScript(idleMinutes: idleMinutes)),
            "Turn on Remote Desktop for Tailscale only");
        _firewall = default;
        _ = Task.Delay(TimeSpan.FromSeconds(6)).ContinueWith(_ => { _firewall = default; Changed?.Invoke(); _ = PostAsync(); });
        return r;
    }

    public JsonObject Status()
    {
        var game = Stats.StatsService.GameExe(_state.GameMode.On ? _state.GameMode.Reason : "");
        return new JsonObject
        {
            ["device_id"] = _state.DeviceId,
            ["edition"] = ProductName,
            ["pro"] = IsPro,
            ["rdp_enabled"] = RdpEnabled,
            ["firewall_scoped"] = FirewallScoped,
            ["hello_only_off"] = HelloOnlyOff,
            ["username"] = Username,
            ["tailscale_ip"] = _tailscaleIp ??= Run("tailscale", "ip -4")?.Split('\n')[0].Trim(),
            ["idle_s"] = IdleSeconds(),
            ["locked"] = _locked,
            ["game"] = game,
            ["remote_session"] = System.Windows.SystemParameters.IsRemoteSession,
            ["has_password"] = HasPassword,
            ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        };
    }

    private async Task PostAsync()
    {
        if (_state.ApiOrigin == null || _state.DeviceId == null) return;
        try
        {
            await _api.PostAsync("/api/rdp/status", Status(), TimeSpan.FromSeconds(10));
            _off = false;
        }
        catch (ApiException e) when (e.Status == 409) { if (!_off) _log("remote-desktop is switched off"); _off = true; }
        catch (Exception e) when (e is ApiException or System.Net.Http.HttpRequestException or TaskCanceledException) { _log("status: " + e.Message); }
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock) _locked = true;
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon) _locked = false;
        else return;
        _ = PostAsync();
    }

    private static double IdleSeconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        return GetLastInputInfo(ref info) ? Math.Round((Environment.TickCount - (int)info.dwTime) / 1000.0, 1) : 0;
    }

    private static string? Run(string file, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(file, args) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true });
            if (p == null) return null;
            var output = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(5000);
            return p.ExitCode == 0 && output.Length > 0 ? output : null;
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }

    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _timer.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
}
