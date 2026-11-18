namespace Jarvis.Core.Startup;

/// Nothing may keep a closed Jarvis alive. Live 2026-11-18: OnExit blocked the UI thread on the services'
/// async clean-up, the window and tray were gone, the process stayed (holding the single-instance lock),
/// the updater couldn't swap it out and every new launch deferred to it.
public static class ExitGuard
{
    public static readonly TimeSpan CleanupBudget = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan HardExitAfter = TimeSpan.FromSeconds(10);

    /// Runs `cleanup` off the calling (UI) thread and waits at most `budget`: true when it finished.
    public static bool RunBounded(Func<Task> cleanup, TimeSpan budget, Action<string> log)
    {
        try
        {
            if (Task.Run(cleanup).Wait(budget)) return true;
            log($"exit: clean-up didn't finish in {budget.TotalSeconds:0} s; leaving it");
        }
        catch (AggregateException e)
        {
            log("exit: clean-up failed: " + (e.InnerException ?? e).Message);
        }
        return false;
    }

    /// A background thread that ends the process after `after`, whatever a foreground thread or a stuck
    /// clean-up is doing.
    public static Thread Arm(TimeSpan after, Action exit)
    {
        var t = new Thread(() =>
        {
            Thread.Sleep(after);
            exit();
        }) { IsBackground = true, Name = "jarvis-exit-guard" };
        t.Start();
        return t;
    }
}

/// A second launch whose "show yourself" got no answer: the running Jarvis is stuck (its UI thread is
/// gone), so end it and take over — unless it only just started (a double launch, still starting up).
public static class StuckInstance
{
    public static readonly TimeSpan MinAge = TimeSpan.FromSeconds(30);

    public static bool TakeOver(bool acked, IEnumerable<(int Pid, DateTime Started)> others, DateTime now,
                                Action<int> kill, Func<int, bool> waitExit, Action<string> log)
    {
        if (acked) return false;
        var list = others.ToList();
        if (list.Any(o => now - o.Started < MinAge))
        {
            log("a Jarvis is still starting up; leaving it");
            return false;
        }
        foreach (var (pid, _) in list)
        {
            log($"the running Jarvis ({pid}) isn't answering: ending it");
            try { kill(pid); }
            catch (Exception e) { log($"couldn't end Jarvis ({pid}): {e.Message}"); }
        }
        return list.All(o => waitExit(o.Pid));
    }
}
