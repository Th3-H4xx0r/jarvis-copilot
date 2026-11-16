using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
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
    /// Present once Set up succeeded: only then may switching the integration back on turn RDP on.
    private static readonly string SetupMarker = Path.Combine(Dir, "rdp.setup");

    private readonly ApiClient _api;
    private readonly AppState _state;
    private readonly AdminRunner _admin;
    private readonly IJcLink _link;
    private readonly Func<string?> _pinnedKey;
    private readonly RdpRelease _release = new();
    private readonly Action<string> _log = FileLog.For("rdp");
    private readonly Timer _timer;
    private bool _locked, _remote;
    private bool? _off;
    private string? _upn, _tailscaleIp;
    private (DateTime At, bool Scoped) _firewall;

    public RemoteDesktop(ApiClient api, AppState state, AdminRunner admin, IJcLink link, Func<string?> pinnedKey)
    {
        _api = api;
        _state = state;
        _admin = admin;
        _link = link;
        _pinnedKey = pinnedKey;
        _link.Message += m => { if (J.S(m["type"]) == "password_release" && J.S(m["kind"]) == "rdp") _ = ReleaseAsync(m); };
        SystemEvents.SessionSwitch += OnSessionSwitch;
        _timer = new Timer(_ => _ = PostAsync(), null, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30));
    }

    public event Action? Changed;

    /// True while this Windows session is shown over RDP (the island, PC Stats window and live share step aside).
    public event Action<bool>? RemoteSessionChanged;

    public static bool IsPro => !Edition.Equals("Core", StringComparison.OrdinalIgnoreCase) && !Edition.StartsWith("Core", StringComparison.OrdinalIgnoreCase);

    /// "Core" (Home), "Professional", "Enterprise", "Education", …
    public static string Edition =>
        Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")?.GetValue("EditionID") as string ?? "";

    /// "Windows 11 Home": the registry still says "Windows 10" on Windows 11, so the build number decides.
    public static string ProductName
    {
        get
        {
            using var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            var name = k?.GetValue("ProductName") as string ?? "Windows";
            return int.TryParse(k?.GetValue("CurrentBuildNumber") as string, out var build) && build >= 22000
                ? name.Replace("Windows 10", "Windows 11") : name;
        }
    }

    /// His Microsoft account's email (Windows records it under IdentityCRL); whoami /upn only works on a domain.
    private static string? MicrosoftAccountEmail()
    {
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\IdentityCRL\UserExtendedProperties");
        return k?.GetSubKeyNames().FirstOrDefault(n => n.Contains('@'));
    }

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
                    // the firewall reports the range in mask form: 100.64.0.0/255.192.0.0
                    if ((string)rule.Name == RdpSetup.RuleName && (string)rule.RemoteAddresses is RdpSetup.TailscaleCidr or "100.64.0.0/255.192.0.0") scoped = true;
            }
            catch (COMException) { }
            _firewall = (DateTime.UtcNow, scoped);
            return scoped;
        }
    }

    public string Username => RdpSetup.Username(_upn ??= MicrosoftAccountEmail() ?? Run("whoami", "/upn"), Environment.UserName);

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
        var script = RdpSetup.SetupScript(idleMinutes: idleMinutes);
        // Same Windows prompt: refresh the Unlock helper too (it now also switches RDP off/on with the integration).
        var helper = Path.Combine(AppContext.BaseDirectory, "JarvisUnlock.exe");
        if (File.Exists(helper))
            script += $"\n& '{helper.Replace("'", "''")}' --install {System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value}";
        var r = await _admin.RunAsync(RdpSetup.PowerShellCommand(script), "Turn on Remote Desktop for Tailscale only");
        if (r.Ok) { Directory.CreateDirectory(Dir); File.WriteAllText(SetupMarker, DateTimeOffset.UtcNow.ToString("O")); }
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
        CheckRemote();
        if (_state.ApiOrigin == null || _state.DeviceId == null) return;
        try
        {
            await _api.PostAsync("/api/rdp/status", Status(), TimeSpan.FromSeconds(10));
            if (_off == true && File.Exists(SetupMarker)) await HelperAsync("on");   // switched back on
            _off = false;
        }
        catch (ApiException e) when (e.Status == 409)
        {
            // The integration is off: Windows' Remote Desktop goes off too (the helper, no UAC).
            if (_off != true && File.Exists(SetupMarker)) { _log("remote-desktop is switched off"); await HelperAsync("off"); }
            _off = true;
        }
        catch (Exception e) when (e is ApiException or System.Net.Http.HttpRequestException or TaskCanceledException) { _log("status: " + e.Message); }
    }

    /// The server relayed his signed Face ID yes for one session: answer it (never logs the password).
    private async Task ReleaseAsync(JsonObject m)
    {
        JsonObject reply;
        try { reply = await Task.Run(() => _release.Handle(m, _pinnedKey() ?? "", ReadPassword, DateTimeOffset.UtcNow)); }
        catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException)
        {
            reply = new JsonObject { ["type"] = "rdp_credential", ["ok"] = false, ["error"] = "Couldn't read the saved password." };
        }
        _log($"release {J.S(reply["session_id"])}: {((bool?)reply["ok"] == true ? "sent" : J.S(reply["error"]))}");
        try { await _link.RequestAsync(reply, TimeSpan.FromSeconds(10)); }
        catch (Exception e) when (e is TimeoutException or InvalidOperationException or IOException) { _log("release reply: " + e.Message); }
    }

    /// Asks the LocalSystem helper (the Unlock service) to switch Windows' Remote Desktop on or off.
    private async Task HelperAsync(string onOff)
    {
        try
        {
            await Task.Run(() =>
            {
                using var pipe = new System.IO.Pipes.NamedPipeClientStream(".", "JarvisUnlock", System.IO.Pipes.PipeDirection.InOut);
                pipe.Connect(3000);
                var req = Encoding.UTF8.GetBytes(new JsonObject { ["rdp"] = onOff }.ToJsonString() + "\n");
                pipe.Write(req, 0, req.Length);
                pipe.Flush();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                _log($"helper rdp {onOff}: {reader.ReadLine()}");
            });
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException) { _log($"helper rdp {onOff}: {e.Message}"); }
        Changed?.Invoke();
    }

    private void CheckRemote()
    {
        var remote = System.Windows.SystemParameters.IsRemoteSession;
        if (remote == _remote) return;
        _remote = remote;
        RemoteSessionChanged?.Invoke(remote);
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock) _locked = true;
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon) _locked = false;
        else if (e.Reason is not (SessionSwitchReason.RemoteConnect or SessionSwitchReason.RemoteDisconnect
                 or SessionSwitchReason.ConsoleConnect or SessionSwitchReason.ConsoleDisconnect)) return;
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
