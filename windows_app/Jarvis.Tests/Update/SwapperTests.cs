using Jarvis.Core.Update;

namespace Jarvis.Tests.Update;

public sealed class FakeFs : ISwapFs
{
    public readonly List<string> Ops = new();
    public readonly HashSet<string> Present = new();
    /// Throw IOException on the first N moves whose source is this path.
    public string? LockedSource;
    public int LockedTimes;

    public void Move(string from, string to)
    {
        if (from == LockedSource && LockedTimes > 0)
        {
            LockedTimes--;
            Ops.Add($"Move!({from}->{to})");
            throw new IOException("locked by antivirus");
        }
        Ops.Add($"Move({from}->{to})");
        Present.Remove(from);
        Present.Add(to);
    }

    public void DeleteTree(string path) { Ops.Add($"DeleteTree({path})"); Present.Remove(path); }
    public bool Exists(string path) => Present.Contains(path);
}

public sealed class FakePs : IProcessOps
{
    public readonly List<string> Ops = new();
    public bool Exits = true;
    public bool Alive = true;
    public bool WaitExit(int pid, TimeSpan timeout) { Ops.Add($"WaitExit({pid},{timeout.TotalSeconds})"); return Exits; }
    public void Kill(int pid) => Ops.Add($"Kill({pid})");
    public int Start(string exe) { Ops.Add($"Start({exe})"); return 777; }
    public bool AliveAfter(int pid, TimeSpan wait) { Ops.Add($"AliveAfter({pid},{wait.TotalSeconds})"); return Alive; }
    public void KillByPath(string exe) => Ops.Add($"KillByPath({exe})");
}

public class SwapperTests
{
    private const string App = "/L/Programs/Jarvis/app";
    private const string Staged = "/L/Jarvis/update/staged";
    private static readonly string Old = App + ".old";
    private static readonly string Exe = Path.Combine(App, "Jarvis.exe");

    private readonly FakeFs _fs = new();
    private readonly FakePs _ps = new();
    private readonly List<string> _log = new();
    private readonly List<TimeSpan> _sleeps = new();

    private Swapper Make()
    {
        _fs.Present.Add(App);
        _fs.Present.Add(Staged);
        return new Swapper(_fs, _ps, _log.Add, _sleeps.Add);
    }

    [Fact]
    public void Swapper_HappyPath()
    {
        Assert.Equal(0, Make().Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(new[] { $"Move({App}->{Old})", $"Move({Staged}->{App})", $"DeleteTree({Old})" }, _fs.Ops);
        Assert.Equal(new[] { "WaitExit(42,60)", $"Start({Exe})", "AliveAfter(777,15)" }, _ps.Ops);
        Assert.Equal("updated", _log.Last());
    }

    [Fact]
    public void Swapper_StaleOldFolderDeletedFirst()
    {
        var s = Make();
        _fs.Present.Add(Old);
        Assert.Equal(0, s.Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal($"DeleteTree({Old})", _fs.Ops[0]);
    }

    [Fact]
    public void Swapper_NewAppDiesWithin15s_RestoresOldAndRelaunches()
    {
        _ps.Alive = false;
        Assert.Equal(1, Make().Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(new[] { $"Move({App}->{Old})", $"Move({Staged}->{App})", $"DeleteTree({App})", $"Move({Old}->{App})" }, _fs.Ops);
        Assert.Equal(new[] { "WaitExit(42,60)", $"Start({Exe})", "AliveAfter(777,15)", $"KillByPath({Exe})", $"Start({Exe})" }, _ps.Ops);
        Assert.StartsWith("restored", _log.Last());
    }

    [Fact]
    public void Swapper_RenameLockedThreeTimes_RestoresOld()
    {
        var s = Make();
        _fs.LockedSource = Staged;
        _fs.LockedTimes = 3;
        Assert.Equal(1, s.Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(3, _fs.Ops.Count(o => o.StartsWith($"Move!({Staged}")));
        Assert.Equal($"Move({Old}->{App})", _fs.Ops.Last());
        Assert.Equal(new[] { TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(500) }, _sleeps);
        Assert.Equal($"Start({Exe})", _ps.Ops.Last());
        Assert.StartsWith("restored", _log.Last());
    }

    [Fact]
    public void Swapper_RenameLockedTwice_StillUpdates()
    {
        var s = Make();
        _fs.LockedSource = Staged;
        _fs.LockedTimes = 2;
        Assert.Equal(0, s.Run(42, App, Staged, "Jarvis.exe"));
    }

    [Fact]
    public void Swapper_OldAppCantMoveAside_StartsOldAndFails()
    {
        var s = Make();
        _fs.LockedSource = App;
        _fs.LockedTimes = 3;
        Assert.Equal(1, s.Run(42, App, Staged, "Jarvis.exe"));
        Assert.DoesNotContain(_fs.Ops, o => o.StartsWith($"Move({Staged}"));
        Assert.Equal($"Start({Exe})", _ps.Ops.Last());
    }

    [Fact]
    public void Swapper_OldAppNeverExits_KilledAfter60s()
    {
        _ps.Exits = false;
        Assert.Equal(0, Make().Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(new[] { "WaitExit(42,60)", "Kill(42)" }, _ps.Ops.Take(2));
    }
}
