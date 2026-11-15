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
        _single = new SingleInstance();
        if (!_single.IsFirst)
        {
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
        _single.ListenForShow(() => Dispatcher.BeginInvoke(() => _host?.ShowIsland()));
        _host.Start(e.Args);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _host?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _single?.Dispose();
        base.OnExit(e);
    }
}
