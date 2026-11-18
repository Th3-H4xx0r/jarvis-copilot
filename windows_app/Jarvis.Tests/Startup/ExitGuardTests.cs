using Jarvis.Core.Startup;

namespace Jarvis.Tests.Startup;

/// Nothing may keep a closed Jarvis alive (live 2026-11-18: OnExit blocked the UI thread on the
/// services' async clean-up, the window and tray were gone, the process stayed, and every new launch
/// deferred to it).
public class ExitGuardTests
{
    [Fact]
    public void RunBounded_GivesUpOnCleanupThatNeverFinishes()
    {
        var never = new TaskCompletionSource();
        var log = new List<string>();
        var started = DateTime.UtcNow;
        Assert.False(ExitGuard.RunBounded(() => never.Task, TimeSpan.FromMilliseconds(150), log.Add));
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(2));
        Assert.Single(log);
    }

    [Fact]
    public void RunBounded_CleanupThatFinishesAndOneThatThrows()
    {
        var log = new List<string>();
        Assert.True(ExitGuard.RunBounded(() => Task.CompletedTask, TimeSpan.FromSeconds(1), log.Add));
        Assert.False(ExitGuard.RunBounded(() => throw new InvalidOperationException("boom"), TimeSpan.FromSeconds(1), log.Add));
        Assert.Contains(log, l => l.Contains("boom"));
    }

    [Fact]
    public void Arm_EndsTheProcessAfterTheDelay()
    {
        var ended = new ManualResetEventSlim();
        var t = ExitGuard.Arm(TimeSpan.FromMilliseconds(50), ended.Set);
        Assert.True(t.IsBackground);
        Assert.True(ended.Wait(TimeSpan.FromSeconds(2)));
    }
}

public class StuckInstanceTests
{
    private static readonly DateTime Now = new(2026, 11, 18, 4, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void ARunningJarvisThatAnswersIsLeftAlone()
    {
        var killed = new List<int>();
        var r = StuckInstance.TakeOver(acked: true, others: new[] { (77, Now.AddMinutes(-30)) }, now: Now,
                                       kill: killed.Add, waitExit: _ => true, log: _ => { });
        Assert.False(r);
        Assert.Empty(killed);
    }

    [Fact]
    public void AnOldSilentJarvisIsEndedSoTheNewLaunchTakesOver()
    {
        var killed = new List<int>();
        var r = StuckInstance.TakeOver(acked: false, others: new[] { (77, Now.AddMinutes(-30)) }, now: Now,
                                       kill: killed.Add, waitExit: _ => true, log: _ => { });
        Assert.True(r);
        Assert.Equal(new[] { 77 }, killed);
    }

    [Fact]
    public void AJarvisStillStartingUpIsNeverKilled()
    {
        // Two quick launches: the first is still starting (not listening yet) — it isn't stuck.
        var killed = new List<int>();
        var r = StuckInstance.TakeOver(acked: false, others: new[] { (77, Now.AddSeconds(-10)) }, now: Now,
                                       kill: killed.Add, waitExit: _ => true, log: _ => { });
        Assert.False(r);
        Assert.Empty(killed);
    }

    [Fact]
    public void OneThatWontDieMeansNoTakeOver()
    {
        var r = StuckInstance.TakeOver(acked: false, others: new[] { (77, Now.AddMinutes(-30)) }, now: Now,
                                       kill: _ => { }, waitExit: _ => false, log: _ => { });
        Assert.False(r);
    }
}
