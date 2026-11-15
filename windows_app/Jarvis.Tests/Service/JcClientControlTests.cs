using Jarvis.Core.Service;
using Xunit;

namespace Jarvis.Tests.Service;

public class JcClientControlTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("jcc").FullName;
    private readonly List<string> _calls = new();
    private string _query = "TaskName: \\JarvisCopilot\\jc-client\r\nStatus:   Ready\r\n";
    private int _queryCode;

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
            return Task.FromResult(args.Contains("/Query") ? (_queryCode, _query) : (0, ""));
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
