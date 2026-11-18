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
    /// When set, WaitExit answers these in turn (then repeats the last).
    public Queue<bool>? ExitAnswers;
    public bool WaitExit(int pid, TimeSpan timeout)
    {
        Ops.Add($"WaitExit({pid},{timeout.TotalSeconds})");
        if (ExitAnswers is { Count: > 0 } q) return q.Count > 1 ? q.Dequeue() : q.Peek();
        return Exits;
    }
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
    public void Swapper_RenameLockedEveryTry_RestoresOld()
    {
        var s = Make();
        _fs.LockedSource = Staged;
        _fs.LockedTimes = Swapper.Tries;
        Assert.Equal(1, s.Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(Swapper.Tries, _fs.Ops.Count(o => o.StartsWith($"Move!({Staged}")));
        Assert.Equal($"Move({Old}->{App})", _fs.Ops.Last());
        Assert.Equal(Enumerable.Repeat(Swapper.RetryGap, Swapper.Tries - 1), _sleeps);
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
        _fs.LockedTimes = Swapper.Tries;
        Assert.Equal(1, s.Run(42, App, Staged, "Jarvis.exe"));
        Assert.DoesNotContain(_fs.Ops, o => o.StartsWith($"Move({Staged}"));
        Assert.Equal($"Start({Exe})", _ps.Ops.Last());
    }

    [Fact]
    public void Swapper_OldAppNeverExits_KilledAfter60s()
    {
        _ps.ExitAnswers = new Queue<bool>(new[] { false, true });
        Assert.Equal(0, Make().Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(new[] { "WaitExit(42,60)", "Kill(42)", "WaitExit(42,10)" }, _ps.Ops.Take(3));
    }

    [Fact]
    public void Swapper_KillThatDoesntTake_EndsItByPath()
    {
        // Live 2026-11-18: the app hung on exit, the kill didn't take, and the restart hit its
        // single-instance lock — he was left with no app at all.
        _ps.ExitAnswers = new Queue<bool>(new[] { false, false, true });
        Assert.Equal(0, Make().Run(42, App, Staged, "Jarvis.exe"));
        Assert.Equal(new[] { "WaitExit(42,60)", "Kill(42)", "WaitExit(42,10)", $"KillByPath({Exe})", "WaitExit(42,10)" },
                     _ps.Ops.Take(5));
    }

    [Fact]
    public void Swapper_FailedSwapClearsAStuckInstanceBeforeRestarting()
    {
        var s = Make();
        _ps.Exits = false;   // the old one never goes
        _fs.LockedSource = App;
        _fs.LockedTimes = Swapper.Tries;
        Assert.Equal(1, s.Run(42, App, Staged, "Jarvis.exe"));
        var start = _ps.Ops.LastIndexOf($"Start({Exe})");
        Assert.True(start > 0 && _ps.Ops[start - 1] == $"KillByPath({Exe})");
    }

    [Fact]
    public void Swapper_GivesAKilledAppTimeToLetGo()
    {
        // Live: the move right after the kill failed "being used by another process" three times in 1 s.
        Assert.True(Swapper.Tries * Swapper.RetryGap.TotalSeconds >= 8);
    }
}
