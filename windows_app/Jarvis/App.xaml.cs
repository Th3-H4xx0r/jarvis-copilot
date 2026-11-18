using System.Windows;
using Jarvis.Core.Startup;
using Jarvis.Platform;

namespace Jarvis;

public partial class App : Application
{
    private SingleInstance? _single;
    private AppHost? _host;

    public AppHost? Host => _host;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // A bug in one feature must not take the whole app down mid-game: log it and carry on.
        DispatcherUnhandledException += (_, ex) =>
        {
            FileLog.Write("app", $"unhandled: {ex.Exception}");
            ex.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => FileLog.Write("app", $"fatal: {ex.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            FileLog.Write("app", $"unobserved: {ex.Exception}");
            ex.SetObserved();
        };
        _single = new SingleInstance();
        if (!_single.IsFirst)
        {
            // `Jarvis.exe --diag …` while Jarvis runs: hand the switch to the running one.
            if (Array.IndexOf(e.Args, "--diag") is var d and >= 0 && d + 1 < e.Args.Length)
                AppHost.QueueDiag(e.Args[(d + 1)..]);
            // The running one shows the island and says so; one that doesn't answer is stuck (live 2026-11-18:
            // its window and tray gone, every launch did nothing): end it and take over.
            if (_single.SignalFirstAndWait(TimeSpan.FromSeconds(5)) || !_single.TakeOverFromStuck(FileLog.For("app")))
            {
                Shutdown();
                return;
            }
            FileLog.Write("app", "took over from a Jarvis that wasn't answering");
        }
        Jarvis.Ui.K.EnableCapsules();
        _host = new AppHost(Dispatcher);
        if (Environment.ProcessPath is { } exe)
        {
            try { StartupRegistration.EnsureDefault(new WinRegistry(), _host.Prefs, exe); }
            catch (UnauthorizedAccessException) { }
        }
        _single.ListenForShow(() => Dispatcher.BeginInvoke(() =>
        {
            if (AppHost.TakeQueuedDiag() is { } diag) _host?.Diag(diag);
            else _host?.ShowIsland();
            _single?.Acknowledge();
        }));
        _host.Start(e.Args);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // Never block the UI thread on async clean-up (that deadlocked: window gone, process alive), and
        // whatever happens, end the process — a foreground thread can't keep a closed Jarvis running.
        var code = e.ApplicationExitCode;
        ExitGuard.Arm(ExitGuard.HardExitAfter, () => Environment.Exit(code));
        if (_host is { } host)
            ExitGuard.RunBounded(() => host.DisposeAsync().AsTask(), ExitGuard.CleanupBudget, line => FileLog.Write("app", line));
        _single?.Dispose();
        base.OnExit(e);
    }
}
