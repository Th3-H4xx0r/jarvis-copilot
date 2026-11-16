using System.Text;

namespace Jarvis.Core.Remote;

/// The PowerShell that turns Windows' Remote Desktop on (or off) the way the design says
/// (docs/superpowers/specs/2026-11-15-remote-desktop-design.md): NLA required, the built-in firewall
/// rules off and one rule letting only Tailscale addresses reach port 3389, H.264/AVC 444 on the GPU,
/// idle sessions disconnected after a while, and "Only allow Windows Hello sign-in" off so his
/// Microsoft account password works for RDP. Run elevated (AdminRunner or the LocalSystem helper).
public static class RdpSetup
{
    public const string RuleName = "Jarvis Remote Desktop (Tailscale)";
    public const string TailscaleCidr = "100.64.0.0/10";
    private const string Ts = @"'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'";
    private const string RdpTcp = @"'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'";
    private const string Policy = @"'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'";
    private const string PasswordLess = @"'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'";

    public static string SetupScript(string tailscaleCidr = TailscaleCidr, int idleMinutes = 30)
    {
        var idleMs = Math.Max(1, idleMinutes) * 60_000;
        return string.Join("\n",
            "$ErrorActionPreference = 'Stop'",
            $"Set-ItemProperty -Path {Ts} -Name fDenyTSConnections -Value 0",
            $"Set-ItemProperty -Path {RdpTcp} -Name UserAuthentication -Value 1",
            $"if (-not (Test-Path {Policy})) {{ New-Item -Path {Policy} -Force | Out-Null }}",
            $"Set-ItemProperty -Path {Policy} -Name AVC444ModePreferred -Value 1 -Type DWord",
            $"Set-ItemProperty -Path {Policy} -Name bEnumerateHWBeforeSW -Value 1 -Type DWord",
            $"Set-ItemProperty -Path {Policy} -Name MaxIdleTime -Value {idleMs} -Type DWord",
            $"if (-not (Test-Path {PasswordLess})) {{ New-Item -Path {PasswordLess} -Force | Out-Null }}",
            $"Set-ItemProperty -Path {PasswordLess} -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord",
            "Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue",
            $"Remove-NetFirewallRule -DisplayName '{RuleName}' -ErrorAction SilentlyContinue",
            $"New-NetFirewallRule -DisplayName '{RuleName}' -Direction Inbound -Protocol TCP -LocalPort 3389 -RemoteAddress {tailscaleCidr} -Action Allow -Profile Any | Out-Null",
            $"New-NetFirewallRule -DisplayName '{RuleName}' -Direction Inbound -Protocol UDP -LocalPort 3389 -RemoteAddress {tailscaleCidr} -Action Allow -Profile Any | Out-Null",
            "Set-Service -Name TermService -StartupType Manual",
            "Start-Service -Name TermService -ErrorAction SilentlyContinue");
    }

    public static string OffScript() => string.Join("\n",
        "$ErrorActionPreference = 'Continue'",
        $"Set-ItemProperty -Path {Ts} -Name fDenyTSConnections -Value 1",
        $"Remove-NetFirewallRule -DisplayName '{RuleName}' -ErrorAction SilentlyContinue");

    /// How RDP wants his name: Microsoft-account sign-ins as MicrosoftAccount\email, local ones as .\user.
    public static string Username(string? upn, string user) =>
        string.IsNullOrWhiteSpace(upn) ? $@".\{user}" : $@"MicrosoftAccount\{upn.Trim()}";

    /// A script as one command line for AdminRunner / the helper (UTF-16 base64, so no quoting trouble).
    public static string PowerShellCommand(string script) =>
        "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
}
