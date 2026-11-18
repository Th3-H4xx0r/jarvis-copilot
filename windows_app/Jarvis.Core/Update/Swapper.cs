namespace Jarvis.Core.Update;

public interface ISwapFs
{
    void Move(string from, string to);
    void DeleteTree(string path);
    bool Exists(string path);
}

public interface IProcessOps
{
    bool WaitExit(int pid, TimeSpan timeout);
    void Kill(int pid);
    int Start(string exe);
    bool AliveAfter(int pid, TimeSpan wait);
    void KillByPath(string exe);
}

/// JarvisUpdater's swap (port of AppUpdateRules.swapScript): wait for Jarvis to exit (kill at
/// 60 s), move `app` aside, move `staged` in, start it, and keep it only if it's still alive 15 s
/// on. Any failure puts the old folder back and starts it. 0 = updated, 1 = restored.
public sealed class Swapper
{
    public static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan KillWait = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan AliveWait = TimeSpan.FromSeconds(15);
    // A killed app's children (WebView2 among them) let go of its folder a few seconds later (live: three
    // tries in one second all failed "being used by another process").
    public static readonly TimeSpan RetryGap = TimeSpan.FromSeconds(1);
    public const int Tries = 10;

    private readonly ISwapFs _fs;
    private readonly IProcessOps _ps;
    private readonly Action<string> _log;
    private readonly Action<TimeSpan> _sleep;

    public Swapper(ISwapFs fs, IProcessOps ps, Action<string> log, Action<TimeSpan>? sleep = null)
    {
        _fs = fs;
        _ps = ps;
        _log = log;
        _sleep = sleep ?? Thread.Sleep;
    }

    public int Run(int pid, string app, string staged, string exeName)
    {
        var old = app + ".old";
        var exe = Path.Combine(app, exeName);
        _log($"swap {staged} -> {app}");

        if (!_ps.WaitExit(pid, ExitWait))
        {
            _log($"Jarvis ({pid}) didn't exit in {ExitWait.TotalSeconds:0} s; killing it");
            _ps.Kill(pid);
            if (!_ps.WaitExit(pid, KillWait))
            {
                _log($"Jarvis ({pid}) is still running after the kill; ending every {exeName} in {app}");
                _ps.KillByPath(exe);
                if (!_ps.WaitExit(pid, KillWait)) _log($"Jarvis ({pid}) won't end");
            }
        }
        if (_fs.Exists(old)) TryDelete(old);

        if (!Retry(() => _fs.Move(app, old)))
        {
            _log("couldn't move the old app aside");
            // A stuck old one would swallow the restart (its single-instance lock): end it first.
            if (!_ps.WaitExit(pid, TimeSpan.Zero)) TryKillByPath(exe);
            TryStart(exe);
            return 1;
        }
        if (!Retry(() => _fs.Move(staged, app))) return Restore(app, old, exe, "move failed", killNew: false);

        int newPid;
        try { newPid = _ps.Start(exe); }
        catch (Exception e) { return Restore(app, old, exe, $"start failed: {e.Message}", killNew: false); }
        if (!_ps.AliveAfter(newPid, AliveWait)) return Restore(app, old, exe, "the new app isn't running", killNew: true);

        TryDelete(old);
        if (_fs.Exists(staged)) TryDelete(staged);
        _log("updated");
        return 0;
    }

    private int Restore(string app, string old, string exe, string why, bool killNew)
    {
        _log($"{why} - restoring");
        if (killNew) { try { _ps.KillByPath(exe); } catch (Exception e) { _log($"kill failed: {e.Message}"); } }
        if (killNew || _fs.Exists(app)) TryDelete(app);
        if (!Retry(() => _fs.Move(old, app))) _log("couldn't put the old app back");
        TryStart(exe);
        _log("restored");
        return 1;
    }

    private bool Retry(Action move)
    {
        for (var i = 0; i < Tries; i++)
        {
            try
            {
                move();
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                _log($"move failed ({i + 1}/{Tries}): {e.Message}");
                if (i < Tries - 1) _sleep(RetryGap);
            }
        }
        return false;
    }

    private void TryDelete(string path)
    {
        try { _fs.DeleteTree(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { _log($"couldn't delete {path}: {e.Message}"); }
    }

    private void TryKillByPath(string exe)
    {
        try { _ps.KillByPath(exe); }
        catch (Exception e) { _log($"kill failed: {e.Message}"); }
    }

    private void TryStart(string exe)
    {
        try { _ps.Start(exe); }
        catch (Exception e) { _log($"couldn't start {exe}: {e.Message}"); }
    }
}
