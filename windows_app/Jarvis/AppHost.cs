using System.Windows.Threading;
using Jarvis.Core.Gaming;
using Jarvis.Core.Link;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Platform;

namespace Jarvis;

/// The composition root: owns the prefs, the link, the state and the presentation gate, and
/// marshals link events onto the WPF Dispatcher (AppState's only caller). Later tasks add
/// their services here.
public sealed class AppHost : IAsyncDisposable
{
    public PrefsStore Prefs { get; }
    public JcLink Link { get; }
    public AppState State { get; }
    public PresentationGate Gate { get; }
    public Dispatcher Dispatcher { get; }

    public AppHost(Dispatcher dispatcher)
    {
        Dispatcher = dispatcher;
        Prefs = new PrefsStore(PrefsStore.DefaultPath);
        Link = new JcLink(EndpointFile.DefaultPath);
        State = new AppState(Link);
        Gate = new PresentationGate(new Win32ForegroundProbe());

        Link.Message += m => Dispatcher.BeginInvoke(() => State.Handle(m));
        Link.ConnectionChanged += up => Dispatcher.BeginInvoke(() => State.OnConnection(up));
        State.GameModeChanged += Gate.SetGameMode;
    }

    public void Start() => Link.Start();

    public async ValueTask DisposeAsync() => await Link.DisposeAsync();
}
