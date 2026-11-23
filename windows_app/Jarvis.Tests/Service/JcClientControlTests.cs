using Jarvis.Core.Service;
using Xunit;

namespace Jarvis.Tests.Service;

public class JcClientControlTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("jcc").FullName;
    private readonly List<string> _calls = new();
    private string _query = "TaskName: \\JarvisCopilot\\jc-client\r\nStatus:   Ready\r\n";
    private int _queryCode;
    private string _status = "";

    private JcClientControl Make(bool installed = true)
    {
        if (installed)
        {
            var exe = Path.Combine(_dir, "Programs", "jc-client", ".venv", "Scripts", "jc-client.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(exe)!);
            File.WriteAllText(exe, "");
        }
        return new JcClientControl(_dir, (exe, args) =>
        {
            _calls.Add(Path.GetFileName(exe) + " " + string.Join(' ', args));
            return Task.FromResult(args.Contains("/Query") ? (_queryCode, _query) : args.Contains("status") ? (0, _status) : (0, ""));
        });
    }

    [Fact]
    public async Task Ready_IsStarted()
    {
        Assert.Equal(JcClientState.Starting, await Make().EnsureRunningAsync());
        Assert.Contains(@"schtasks.exe /Run /TN \JarvisCopilot\jc-client", _calls);
    }

    [Fact]
    public async Task Running_IsLeftAlone()
    {
        _query = "Status:   Running\r\n";
        Assert.Equal(JcClientState.Running, await Make().EnsureRunningAsync());
        Assert.DoesNotContain(_calls, c => c.Contains("/Run"));
    }

    [Fact]
    public async Task Disabled_MeansStoppedOnPurpose_NotStarted()
    {
        _query = "Status:   Disabled\r\n";
        Assert.Equal(JcClientState.Stopped, await Make().EnsureRunningAsync());
        Assert.DoesNotContain(_calls, c => c.Contains("/Run"));
    }

    [Fact]
    public async Task Disabled_BecauseItIsntPairedYet_IsStartedSoTheAppCanShowThePairScreen()
    {
        // The installer leaves the task disabled until it's paired; the app's QR screen needs it running.
        _query = "Status:   Disabled\r\n";
        _status = "jc-client 0.1\r\n  paired:        no\r\n";
        Assert.Equal(JcClientState.Starting, await Make().EnsureRunningAsync());
        Assert.Equal(new[] { @"schtasks.exe /Query /TN \JarvisCopilot\jc-client /FO LIST", "jc-client.exe status", "jc-client.exe restart" }, _calls);
    }

    [Fact]
    public async Task Disabled_WhilePaired_StaysStopped_AndIsAskedOnlyOnce()
    {
        _query = "Status:   Disabled\r\n";
        _status = "  paired:        yes\r\n";
        var c = Make();
        Assert.Equal(JcClientState.Stopped, await c.EnsureRunningAsync());
        Assert.Equal(JcClientState.Stopped, await c.EnsureRunningAsync());   // the 1-minute watch: no Python run each time
        Assert.Single(_calls, x => x == "jc-client.exe status");
        Assert.DoesNotContain(_calls, x => x.Contains("restart") || x.Contains("/Run"));
    }

    [Theory]
    [InlineData(0, "  paired:        yes\n  server: https://j.example\n", true)]
    [InlineData(0, "  paired:        no\n", false)]
    [InlineData(0, "PAIRED: No", false)]
    [InlineData(0, "", null)]
    [InlineData(1, "  paired:        no\n", null)]
    public void ParsePaired(int code, string output, bool? paired) => Assert.Equal(paired, JcClientControl.ParsePaired(code, output));

    [Fact]
    public async Task NotInstalled_RunsNothing()
    {
        Assert.Equal(JcClientState.Missing, await Make(installed: false).EnsureRunningAsync());
        Assert.Empty(_calls);
    }

    [Fact]
    public async Task NoTask_IsMissing()
    {
        _queryCode = 1;
        Assert.Equal(JcClientState.Missing, await Make().EnsureRunningAsync());
    }

    [Fact]
    public async Task RestartAndStop_UseTheClientsOwnCommands()
    {
        var c = Make();
        await c.RestartAsync();
        await c.StopAsync();
        Assert.Equal(new[] { "jc-client.exe restart", "jc-client.exe stop" }, _calls);
    }

    public void Dispose() => Directory.Delete(_dir, true);
}
