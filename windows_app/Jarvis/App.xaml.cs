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
            _single.SignalFirst();
            Shutdown();
            return;
        }
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
        }));
        _host.Start(e.Args);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _host?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _single?.Dispose();
        base.OnExit(e);
    }
}
