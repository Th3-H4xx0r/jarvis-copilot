using System.Text.RegularExpressions;
using Jarvis.Core.Remote;
using Xunit;

namespace Jarvis.Tests.Remote;

public class RdpSetupTests
{
    private static int Count(string s, string needle) => Regex.Matches(s, Regex.Escape(needle)).Count;

    [Fact]
    public void SetupScript_contains_every_setting()
    {
        var s = RdpSetup.SetupScript();
        foreach (var needle in new[]
        {
            @"'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0",
            @"'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1",
            "-Name AVC444ModePreferred -Value 1",
            "-Name bEnumerateHWBeforeSW -Value 1",
            "-Name MaxIdleTime -Value 1800000",
            "-Name DevicePasswordLessBuildVersion -Value 0",
        })
            Assert.Equal(1, Count(s, needle));
    }

    [Fact]
    public void Idle_minutes_become_milliseconds()
    {
        Assert.Contains("-Name MaxIdleTime -Value 600000", RdpSetup.SetupScript(idleMinutes: 10));
    }

    [Fact]
    public void Setup_firewall_scoped_to_tailscale_only()
    {
        var s = RdpSetup.SetupScript();
        Assert.Contains("Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'", s);
        var rules = Regex.Matches(s, "New-NetFirewallRule[^\\n]*").Select(m => m.Value).ToList();
        Assert.Equal(2, rules.Count);                                 // TCP and UDP
        Assert.All(rules, r => Assert.Contains("-RemoteAddress 100.64.0.0/10", r));
        Assert.All(rules, r => Assert.Contains("-LocalPort 3389", r));
        Assert.All(rules, r => Assert.Contains($"-DisplayName '{RdpSetup.RuleName}'", r));
        Assert.Contains($"Remove-NetFirewallRule -DisplayName '{RdpSetup.RuleName}'", s);   // idempotent re-run
    }

    [Fact]
    public void OffScript_reverses_rdp_and_rule()
    {
        var s = RdpSetup.OffScript();
        Assert.Contains("-Name fDenyTSConnections -Value 1", s);
        Assert.Contains($"Remove-NetFirewallRule -DisplayName '{RdpSetup.RuleName}'", s);
        Assert.DoesNotContain("New-NetFirewallRule", s);
    }

    [Theory]
    [InlineData("krish@x.com", "krish", "krish@x.com")]
    [InlineData(null, "krish", @".\krish")]
    [InlineData("", "krish", @".\krish")]
    public void Username_for_microsoft_account(string? upn, string user, string expected)
    {
        Assert.Equal(expected, RdpSetup.Username(upn, user));
    }

    [Fact]
    public void Encoded_command_round_trips()
    {
        var cmd = RdpSetup.PowerShellCommand("Write-Output 'hi'");
        Assert.StartsWith("powershell.exe -NoProfile -NonInteractive -EncodedCommand ", cmd);
        var b64 = cmd.Split(' ').Last();
        Assert.Equal("Write-Output 'hi'", System.Text.Encoding.Unicode.GetString(Convert.FromBase64String(b64)));
    }
}
