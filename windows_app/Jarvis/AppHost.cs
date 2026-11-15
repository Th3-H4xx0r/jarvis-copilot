using System.Windows;
using System.Windows.Threading;
using Jarvis.Admin;
using Jarvis.Core.Admin;
using Jarvis.Core.Gaming;
using Jarvis.Core.Http;
using Jarvis.Core.Input;
using Jarvis.Core.Island;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Core.Power;
using Jarvis.Core.PowerInt;
using Jarvis.Core.Prefs;
using Jarvis.Core.Sounds;
using Jarvis.Core.State;
using Jarvis.Core.Tray;
using Jarvis.Input;
using Jarvis.Island;
using Jarvis.Platform;
using Jarvis.Recap;
using Jarvis.Settings;
using Jarvis.Sounds;
using Jarvis.Terminal;
using Jarvis.Tray;
using Jarvis.Voice;
using Jarvis.Voice.Audio;
using Jarvis.Orb;
using Jarvis.Wake;
using Jarvis.Core.Voice;

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
    public ApiClient Api { get; }
    public IslandPresenter Island { get; }
    public IslandWindow IslandWindow { get; }
    public AgentsTab AgentsTab { get; }
    public SoundCenter Sounds { get; }
    public HotKeyCenter HotKeys { get; }
    public HoldKeyWatcher HoldKeys { get; }
    public TerminalJumper Jumper { get; }
    public TrayIcon Tray { get; }
    public PcPowerClient PcPower { get; }
    public PowerRelay PowerRelay { get; }
    public PowerBroadcastWatcher PowerWatcher { get; }
    public AdminRunner Admin { get; }
    public AdminCard AdminCard { get; }
    public PowerApi PowerApi { get; }
    public AudioEndpoints AudioEndpoints { get; }
    public VoiceCaptureDsp Mic { get; }
    public ReplyPlayer Speaker { get; }
    public VoiceController Voice { get; }
    public VoiceTab VoiceTab { get; }
    public PushToTalk PushToTalk { get; }
    public SpeakBack SpeakBack { get; }
    public ForegroundWatcher Foreground { get; }
    public ScreenGlow Glow { get; }
    public DesktopOrbWindow Orb { get; }
    public WakeWordListener? Wake { get; }

    /// What each global shortcut does; later tasks add theirs (orb, Holo Drop, record a call…).
    public Dictionary<ShortcutAction, Action> ShortcutHandlers { get; } = new();
    /// Tray commands the app handles; later tasks add theirs.
    public Dictionary<TrayCommand, Action> TrayHandlers { get; } = new();

    private readonly SessionCursor _cursor = new();
    private RecapWindow? _recap;

    public AppHost(Dispatcher dispatcher)
    {
        Dispatcher = dispatcher;
        Time = new DispatcherTimeProvider(dispatcher);
        Prefs = new PrefsStore(PrefsStore.DefaultPath);
        Link = new JcLink(EndpointFile.DefaultPath);
        State = new AppState(Link, Time);
        Gate = new PresentationGate(new Win32ForegroundProbe(), Time);
        Api = new ApiClient(() => State.ApiOrigin);

        Link.Message += m => Dispatcher.BeginInvoke(() => State.Handle(m));
        Link.ConnectionChanged += up => Dispatcher.BeginInvoke(() => State.OnConnection(up));
        State.GameModeChanged += Gate.SetGameMode;

        // ── Task 5: the island and its Agents tab ──
        Island = new IslandPresenter(State, Gate, Prefs, Time);
        IslandWindow = new IslandWindow(Island, State, Prefs);
        AgentsTab = new AgentsTab(State, Island, () => IslandWindow);
        IslandWindow.Register(IslandTab.Agents, AgentsTab);

        // ── Task 6: sounds, hotkeys, hold keys, jump to terminal, tray, recap ──
        Sounds = new SoundCenter(new SoundPlayer(), Prefs, Gate);
        State.MomentRaised += (m, _) => Sounds.Play(SoundEvents.For(m));
        ApprovalCard.DecisionMade += () => Sounds.Play(SoundEvent.Decided);

        Jumper = new TerminalJumper(() => State.GameMode);
        AgentsTab.JumpRequested += JumpTo;
        AgentsTab.ReadAloudRequested += State.ReadAloud;

        HoldKeys = new HoldKeyWatcher();
        HotKeys = new HotKeyCenter();
        HotKeys.Pressed += a => { if (ShortcutHandlers.TryGetValue(a, out var h)) h(); };
        ShortcutHandlers[ShortcutAction.ToggleIsland] = Island.Click;
        ShortcutHandlers[ShortcutAction.OpenChat] = () => Island.Open(IslandTab.Chat, typing: true);
        ShortcutHandlers[ShortcutAction.GoToAlert] = () => Island.Open(IslandTab.Agents);
        ShortcutHandlers[ShortcutAction.JumpToTerminal] = () =>
        {
            if ((_cursor.Current(State.Sessions) ?? State.Lead) is { } s) JumpTo(s);
        };
        ShortcutHandlers[ShortcutAction.NextSession] = () => SelectSession(1);
        ShortcutHandlers[ShortcutAction.PreviousSession] = () => SelectSession(-1);
        ShortcutHandlers[ShortcutAction.Mute] = () =>
        {
            Sounds.Muted = !Sounds.Muted;
            Island.ShowNotice(Sounds.Muted ? "Sounds muted." : "Sounds on.");
        };
        BindShortcuts();
        Prefs.Changed += k => { if (k.StartsWith("shortcut.", StringComparison.Ordinal)) BindShortcuts(); };

        // ── Task 7: Settings, PC power, sleep/wake relay ──
        PcPower = new PcPowerClient(Link);
        PowerRelay = new PowerRelay(Link, TimeProvider.System);   // its 4 s wait runs while the UI thread is blocked
        PowerWatcher = new PowerBroadcastWatcher(PowerRelay);
        State.PowerTopic += () => _ = PcPower.RefreshAsync();
        State.HelloReceived += () => _ = PcPower.RefreshAsync();
        SettingsWindow.RegisterNative("general", () => GeneralPane.Build(Prefs));
        SettingsWindow.RegisterNative("agents", () => AgentsPane.Build(State));
        SettingsWindow.RegisterNative("pc-power", () => PcPowerPane.Build(PcPower, PowerRelay));
        SettingsWindow.RegisterNative("shortcuts", () => ShortcutsPane.Build(Prefs, HotKeys, BindShortcuts));

        // ── Task 8: Power integrations and the phone-Face-ID admin flow (C6) ──
        Admin = new AdminRunner(Link);
        AdminCard = new AdminCard(Admin, Gate);
        PowerApi = new PowerApi(Api);
        SettingsWindow.RegisterNative("power", () => PowerPane.Build(PowerApi));

        // ── Task 10: the voice engine and the island Voice tab ──
        AudioEndpoints = new AudioEndpoints();
        Mic = new VoiceCaptureDsp();
        Speaker = new ReplyPlayer();
        var routes = new DeviceRoutes(AudioEndpoints, Mic, Speaker);
        var sessions = new VoiceSessionApi(Api);
        Voice = new VoiceController(() => State.ApiOrigin, sessions.SessionIdAsync, () => new VoiceSocket(), routes, Mic, Speaker,
            SapiWordsRecognizer.TryCreate());
        var voiceLog = FileLog.For("voice");
        Voice.Log += voiceLog;
        Mic.Log += voiceLog;
        routes.Log += voiceLog;
        VoiceTab = new VoiceTab(Voice);
        IslandWindow.Register(IslandTab.Voice, VoiceTab);
        SpeakBack = new SpeakBack(() => State.ApiOrigin);
        State.Speak += job => _ = SpeakBack.SpeakAsync(job);
        PushToTalk = new PushToTalk(HoldKeys, Voice, Prefs, Link);
        // Voice answers in game mode too, but the island only opens when it may draw.
        PushToTalk.Started += () => { if (Gate.CanPresent) Island.Open(IslandTab.Voice); };

        // ── Task 11: Hey Jarvis, screen glow, desktop orb, Talk pane ──
        Glow = new ScreenGlow(Gate);
        Orb = new DesktopOrbWindow(Prefs, Gate, Voice, Island);
        Foreground = new ForegroundWatcher();
        Foreground.Changed += OnPresentationMaybeChanged;
        State.GameModeChanged += _ => OnPresentationMaybeChanged();
        ShortcutHandlers[ShortcutAction.DesktopOrb] = Orb.Toggle;
        try
        {
            if (System.IO.File.Exists(System.IO.Path.Combine(WakeWordListener.DefaultModelDir, "hey_jarvis_v0.1.onnx")))
                Wake = new WakeWordListener(WakeWordListener.DefaultModelDir);
        }
        catch (Exception e) when (e is Microsoft.ML.OnnxRuntime.OnnxRuntimeException or DllNotFoundException or TypeInitializationException)
        {
            voiceLog($"wake word unavailable: {e.Message}");
        }
        if (Wake != null)
        {
            Wake.Log += voiceLog;
            Wake.Heard += () => Dispatcher.BeginInvoke(() =>
            {
                if (Voice.State.IsActive()) return;
                _ = Voice.StartConversationAsync("wake");
                if (Gate.CanPresent) Island.Open(IslandTab.Voice);
            });
        }
        Voice.Changed += () => Dispatcher.BeginInvoke(SyncVoiceSurfaces);
        Prefs.Changed += k => { if (k == PrefKeys.WakeEnabled.Name) SyncVoiceSurfaces(); };
        State.HelloReceived += SyncVoiceSurfaces;
        SettingsWindow.RegisterNative("talk", () => TalkPane.Build(Prefs, AudioEndpoints, () => Wake?.Listening ?? false));
        Orb.Update();

        Tray = new TrayIcon(State, () => PcPower.Last?.KeepAwake ?? false, () => false);
        TrayHandlers[TrayCommand.Settings] = () => ShowSettings();
        TrayHandlers[TrayCommand.KeepAwake] = () => _ = PcPower.SetKeepAwakeAsync(!(PcPower.Last?.KeepAwake ?? false));
        Tray.Command += c => { if (TrayHandlers.TryGetValue(c, out var h)) h(); };
        TrayHandlers[TrayCommand.OpenIsland] = ShowIsland;
        TrayHandlers[TrayCommand.Recap] = ShowRecap;
        TrayHandlers[TrayCommand.Quit] = () => Application.Current.Shutdown();
        State.IslandRequested += (tab, _) => { if (tab == "recap") ShowRecap(); };
    }

    /// The foreground or game mode changed: everything that floats re-checks whether it may draw.
    private void OnPresentationMaybeChanged()
    {
        Island.Recheck();
        Orb.Update();
        if (!Gate.CanPresent) Glow.HideGlow();
    }

    /// The wake listener pauses while a conversation owns the mic; the glow shows while listening.
    private void SyncVoiceSurfaces()
    {
        var active = Voice.State.IsActive();
        if (Wake != null)
        {
            if (!active && Prefs.Get(PrefKeys.WakeEnabled) && State.Connected) Wake.Start();
            else Wake.Stop();
        }
        if (Voice.State == VoiceState.Listening) Glow.ShowOn(Monitors.At(Monitors.Cursor()));
        else Glow.HideGlow();
    }

    public void BindShortcuts()
    {
        foreach (var a in ShortcutActions.All) HotKeys.Bind(a, a.Binding(Prefs));
    }

    private void JumpTo(AgentSession s)
    {
        if (Jumper.Jump(s) is { } problem) Island.ShowNotice(problem);
    }

    private void SelectSession(int by)
    {
        if (_cursor.Move(State.Sessions, by) is { } s)
        {
            Island.ShowNotice($"{s.Project} · {s.AgentName} (Ctrl+Alt+T jumps to it)");
            Island.Open(IslandTab.Agents);
        }
    }

    public void ShowSettings(string? pane = null) => SettingsWindow.Show(State, pane);

    public void ShowRecap()
    {
        if (_recap is { IsLoaded: true }) { _recap.Activate(); return; }
        _recap = new RecapWindow(Api);
        _recap.Closed += (_, _) => _recap = null;
        _recap.Show();
    }

    public void Start(string[] args)
    {
        if (args.Contains("--demo")) RunDemo();
        if (Array.IndexOf(args, "--diag") is var i and >= 0 && i + 1 < args.Length) Diag(args[(i + 1)..]);
        Link.Start();
    }

    /// Dev switches for desktop verification over the PC scripts.
    private void Diag(string[] rest)
    {
        switch (rest[0])
        {
            case "open-tray-menu": Tray.OpenMenu(); break;
            case "island": ShowIsland(); break;
            case "settings": ShowSettings(rest.Length > 1 ? rest[1] : null); break;
        }
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

    public async ValueTask DisposeAsync()
    {
        Tray.Dispose();
        PowerWatcher.Dispose();
        await Voice.StopAsync();
        Mic.Dispose();
        Wake?.Dispose();
        Foreground.Dispose();
        Speaker.Dispose();
        AudioEndpoints.Dispose();
        HotKeys.Dispose();
        HoldKeys.Dispose();
        await Link.DisposeAsync();
    }
}
