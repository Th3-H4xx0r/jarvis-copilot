using System.Windows.Threading;
using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Island;
using Jarvis.Platform;

namespace Jarvis;

/// The composition root: owns the prefs, the link, the state and the presentation gate, and
/// marshals link events onto the WPF Dispatcher (AppState's only caller). Every Core timer runs
/// on the Dispatcher too (DispatcherTimeProvider). Each task adds its services here.
public sealed class AppHost : IAsyncDisposable
{
    public PrefsStore Prefs { get; }
    public JcLink Link { get; }
    public AppState State { get; }
    public PresentationGate Gate { get; }
    public Dispatcher Dispatcher { get; }
    public TimeProvider Time { get; }
    public IslandPresenter Island { get; }
    public IslandWindow IslandWindow { get; }
    public AgentsTab AgentsTab { get; }

    public AppHost(Dispatcher dispatcher)
    {
        Dispatcher = dispatcher;
        Time = new DispatcherTimeProvider(dispatcher);
        Prefs = new PrefsStore(PrefsStore.DefaultPath);
        Link = new JcLink(EndpointFile.DefaultPath);
        State = new AppState(Link, Time);
        Gate = new PresentationGate(new Win32ForegroundProbe(), Time);

        Link.Message += m => Dispatcher.BeginInvoke(() => State.Handle(m));
        Link.ConnectionChanged += up => Dispatcher.BeginInvoke(() => State.OnConnection(up));
        State.GameModeChanged += Gate.SetGameMode;

        // ── Task 5: the island and its Agents tab ──
        Island = new IslandPresenter(State, Gate, Prefs, Time);
        IslandWindow = new IslandWindow(Island, State, Prefs);
        AgentsTab = new AgentsTab(State, Island, () => IslandWindow);
        IslandWindow.Register(IslandTab.Agents, AgentsTab);
    }

    public void Start(string[] args)
    {
        if (args.Contains("--demo")) RunDemo();
        Link.Start();
    }

    /// `Jarvis.exe --demo`: the made-up tour (sessions working, an approval, a question, a finish).
    public void RunDemo()
    {
        foreach (var step in DemoData.Steps)
        {
            var s = step;
            Time.CreateTimer(_ => State.SetDemo(s.Sessions, s.Pending), null, TimeSpan.FromSeconds(s.AtSeconds), Timeout.InfiniteTimeSpan);
        }
        Time.CreateTimer(_ => State.EndDemo(), null, TimeSpan.FromSeconds(DemoData.EndsAtSeconds), Timeout.InfiniteTimeSpan);
    }

    /// A second launch, or the tray, asked for the island.
    public void ShowIsland() => Island.Open(IslandTab.Agents);

    public async ValueTask DisposeAsync() => await Link.DisposeAsync();
}
