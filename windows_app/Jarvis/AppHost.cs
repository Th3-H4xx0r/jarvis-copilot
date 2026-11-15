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
using Jarvis.Screen;
using Jarvis.Core.Screen;
using Jarvis.HoloDrop;
using Jarvis.Core.Holo;
using Jarvis.Chat;
using Jarvis.Music;
using Jarvis.Core.Chat;
using Jarvis.Notes;
using Jarvis.Flow;
using Jarvis.Core.Flow;
using Jarvis.Live;
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
using Jarvis.Ui;

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
    public LiveController Live { get; }
    public FlowStore FlowStore { get; }
    public FlowCapture FlowCapture { get; }
    public FlowController Flow { get; }
    public FlowPill FlowPill { get; }
    public NoteTaker NoteTaker { get; }
    public FrontWindowProbe FrontProbe { get; }
    public ChatStore Chat { get; }
    public MediaSessions Media { get; }
    public HoloDropService Holo { get; }
    public HoloSender HoloSender { get; }
    public HoloFlingWatcher Fling { get; }
    public ScreenShareService ScreenShare { get; }
    public ShareBanner ShareBanner { get; }

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

        // ── Task 12: Live Jarvis ──
        Live = new LiveController(() => State.ApiOrigin, () => State.DeviceId);
        VoiceTab.LiveRequested += ShowLive;

        // ── Task 13: Flow dictation ──
        FlowStore = new FlowStore();
        FlowCapture = new FlowCapture();
        var paster = new FlowPaster(new WpfClipboard(), new SendInputKeys(), global::Jarvis.Flow.Foreground.ElevatedAboveUs, Time);
        Flow = new FlowController(Api, () => State.ApiOrigin, paster, FlowCapture, () => State.GameMode, FlowStore.LoadSettings, global::Jarvis.Flow.Foreground.Exe, Time);
        FlowPill = new FlowPill(Flow, FlowCapture);
        var flowClock = System.Diagnostics.Stopwatch.StartNew();
        var flowTick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        flowTick.Tick += (_, _) => { Flow.Tick(flowClock.Elapsed.TotalSeconds); if (!Flow.TickNeeded) flowTick.Stop(); };
        HoldKeys.Changed += (name, down) =>
        {
            if (name == "flow") Flow.OnKey(down, flowClock.Elapsed.TotalSeconds);
            else if (name == "flow-esc" && down) Flow.OnEscape();
            if (Flow.TickNeeded) flowTick.Start();
        };
        HoldKeys.OtherKey += Flow.OnOtherKey;
        Flow.Pasted += _ =>
        {
            var stats = FlowStore.LoadStats();
            foreach (var (day, d) in Flow.Stats.Days) stats.Add(d.Words, d.Seconds, null, day);
            Flow.Stats.Days.Clear();
            FlowStore.SaveStats(stats);
        };
        SyncFlowKey();
        Prefs.Changed += k => { if (k is "flow.key" or "flow.enabled") SyncFlowKey(); };
        SettingsWindow.RegisterNative("flow", () => FlowPane.Build(Prefs, FlowStore, Flow));

        // ── Task 15: the island's Chat and Music tabs ──
        FrontProbe = new FrontWindowProbe();
        Chat = new ChatStore(Api) { Origin = () => State.ApiOrigin };
        IslandWindow.Register(IslandTab.Chat, new ChatTab(Chat, Island, () => IslandWindow));
        Media = new MediaSessions();
        IslandWindow.Register(IslandTab.Music, new MusicTab(Media));
        ShortcutHandlers[ShortcutAction.AttachWindow] = () =>
        {
            // The island never has focus, so the foreground window is still his.
            Chat.Attached = FrontProbe.Front();
            Island.Open(IslandTab.Chat, typing: true);
        };

        // ── Tasks 16/17: Holo Drop receive and send ──
        HoloDropService? holo = null;
        var holoApi = new HoloDropApi(Api);
        holo = new HoloDropService(holoApi, Gate,
            new HoloPorts(new HoloReceiver(), new HoloCards(() => holo), new HoloBeacons(), new HoloScreenReport(), new HoloBleBeacon(), new HoloFirewallProbe()),
            new HoloDropOptions
            {
                GameMode = () => State.GameMode,
                DeviceId = () => State.DeviceId,
                Admin = Admin,
                Dispatch = a => Dispatcher.Invoke(a),
            });
        Holo = holo;
        State.HoloFrame += f => Holo.Handle(f);
        State.HelloReceived += () => _ = Holo.ServerReadyAsync();
        State.PowerTopic += () => _ = Holo.PowerTopicAsync();
        PowerWatcher.Woke += () => _ = Holo.DidWakeAsync();
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += (_, _) => _ = Holo.NetworkChangedAsync();
        HoloSender = new HoloSender(holoApi);
        ShortcutHandlers[ShortcutAction.HoloDrop] = () => OpenOrbit();
        GeneralPane.Extras.Add(HoloFirewallRow);
        Fling = new HoloFlingWatcher();
        Fling.Flung += angle => Dispatcher.BeginInvoke(() =>
        {
            var orbit = OpenOrbit();
            orbit?.SendToward(angle);
        });
        HoldKeys.Changed += (name, down) =>
        {
            if (name == "fling-ctrl") _flingCtrl = down;
            else if (name == "fling-alt") _flingAlt = down;
            else return;
            Fling.Update(Prefs.Get(PrefKeys.HoloFling), _flingCtrl && _flingAlt, State.GameMode);
        };
        SyncFlingKeys();
        Prefs.Changed += k => { if (k == PrefKeys.HoloFling.Name) SyncFlingKeys(); };
        ShortcutsPane.Extras.Add(() => Th.Switch("Mouse fling: hold left Ctrl+Alt and flick the mouse toward a device", Prefs.Get(PrefKeys.HoloFling),
            v => Prefs.Set(PrefKeys.HoloFling, v)));

        // ── Task 18: screen share, Command Center and remote input, under the game guard ──
        var screenLog = FileLog.For("screen");
        ScreenShareFactory? shares = null;
        var pcControls = new PcControls(Media, PcPower,
            id => shares?.Current?.ShowDisplay(Monitors.All().FirstOrDefault(m => PcControls.DisplayNumber(m.Name) == id)) ?? "Nothing is being shared.",
            () => shares?.Current?.Display is { } d ? PcControls.DisplayNumber(d.Name) : 0);
        ScreenShareService? screen = null;
        shares = new ScreenShareFactory(Api, new SendInputSink(), pcControls, screenLog, id => screen?.SessionEnded(id));
        screen = new ScreenShareService(Api, () => State.DeviceId, () => State.GameMode, shares);
        ScreenShare = screen;
        ShareBanner = new ShareBanner(() =>
        {
            if (shares.Current is { } live)
                _ = Api.PostAsync(ShareSelection.StopPath(live.Id), new System.Text.Json.Nodes.JsonObject { ["error"] = "Stopped on the PC." }, TimeSpan.FromSeconds(10));
            ScreenShare.StopAll("Stopped on the PC.");
        });
        void UpdateBanner() => Dispatcher.BeginInvoke(() => ShareBanner.Update(ScreenShare.Capturing && Gate.CanPresent, ScreenShare.Viewers));
        shares.CurrentChanged += () =>
        {
            if (shares.Current is { } live) live.ViewersChanged += UpdateBanner;
            UpdateBanner();
        };
        State.ScreenSharesPoke += () => _ = ScreenShare.PollAsync();
        State.HelloReceived += () => _ = ScreenShare.PollAsync();
        State.GameModeChanged += m => _ = ScreenShare.GameModeChangedAsync(m);
        var sharePoll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        sharePoll.Tick += (_, _) => { if (State.Connected) _ = ScreenShare.PollAsync(); };
        sharePoll.Start();

        // ── Task 14: the note-taker (RecordCall has no default chord, as on the Mac) ──
        NoteTaker = new NoteTaker(Api, () => State.ApiOrigin);
        ShortcutHandlers[ShortcutAction.RecordCall] = () => _ = NoteTaker.ToggleAsync();

        Tray = new TrayIcon(State, () => PcPower.Last?.KeepAwake ?? false, () => NoteTaker.Recording);
        TrayHandlers[TrayCommand.RecordCall] = () =>
        {
            _ = NoteTaker.ToggleAsync();
            ShowNotes();
        };
        TrayHandlers[TrayCommand.Settings] = () => ShowSettings();
        TrayHandlers[TrayCommand.KeepAwake] = () => _ = PcPower.SetKeepAwakeAsync(!(PcPower.Last?.KeepAwake ?? false));
        Tray.Command += c => { if (TrayHandlers.TryGetValue(c, out var h)) h(); };
        TrayHandlers[TrayCommand.OpenIsland] = ShowIsland;
        TrayHandlers[TrayCommand.Recap] = ShowRecap;
        TrayHandlers[TrayCommand.HoloDrop] = () => OpenOrbit();
        TrayHandlers[TrayCommand.Live] = ShowLive;
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

    /// Flow watches its key (and Esc) only while it is on.
    private void SyncFlowKey()
    {
        if (Prefs.Get(PrefKeys.FlowEnabled) && Jarvis.Core.Input.HoldKeys.Vk(Prefs.Get(PrefKeys.FlowKey)) is { } vk)
        {
            HoldKeys.Watch("flow", vk);
            HoldKeys.Watch("flow-esc", 0x1B);
        }
        else
        {
            HoldKeys.Unwatch("flow");
            HoldKeys.Unwatch("flow-esc");
        }
    }

    private bool _flingCtrl, _flingAlt;

    /// Left Ctrl and left Alt are watched (Raw Input) only while the fling is switched on.
    private void SyncFlingKeys()
    {
        if (Prefs.Get(PrefKeys.HoloFling)) { HoldKeys.Watch("fling-ctrl", 0xA2); HoldKeys.Watch("fling-alt", 0xA4); }
        else { HoldKeys.Unwatch("fling-ctrl"); HoldKeys.Unwatch("fling-alt"); Fling.Update(false, false, State.GameMode); }
    }

    private HoloOrbitWindow? _orbit;

    /// Ctrl+Alt+H: grab what's in front and open the Orbit (never over a game).
    public HoloOrbitWindow? OpenOrbit()
    {
        if (!Gate.CanPresent || !Holo.On) return null;
        if (_orbit is { IsLoaded: true }) return _orbit;
        var item = HoloGrab.Grab(FrontProbe, System.IO.File.Exists);
        _orbit = new HoloOrbitWindow(Holo, HoloSender, item, Holo.Devices);
        _orbit.Closed += (_, _) => _orbit = null;
        _orbit.Present();
        return _orbit;
    }

    private FrameworkElement HoloFirewallRow()
    {
        var panel = new System.Windows.Controls.StackPanel();
        panel.Children.Add(Th.Text("HOLO DROP", 11, "JcTextFaint", bold: true));
        if (Holo.FirewallNeeded)
        {
            panel.Children.Add(Th.Text("Phones on your Wi-Fi can send straight to this PC once Windows allows it. You approve with Face ID on your iPhone, then click Yes on Windows' prompt.", 12, "JcTextDim", wrap: true));
            panel.Children.Add(Th.Button(HoloFirewall.Why, () => _ = Holo.AllowFirewallAsync()));
        }
        else panel.Children.Add(Th.Text(Holo.On ? $"On. Drops are saved to {Holo.SaveFolder}." : "Off (Settings → Power integrations).", 12, "JcTextDim", wrap: true));
        panel.Margin = new Thickness(0, 22, 0, 0);
        return panel;
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

    private LivePanel? _livePanel;

    public void ShowLive()
    {
        if (_livePanel is { IsLoaded: true }) { _livePanel.Activate(); return; }
        _livePanel = new LivePanel(Live);
        _livePanel.Closed += (_, _) => _livePanel = null;
        _livePanel.Show();
    }

    private NotesWindow? _notesWindow;

    public void ShowNotes()
    {
        if (_notesWindow is { IsLoaded: true }) { _notesWindow.Activate(); return; }
        _notesWindow = new NotesWindow(NoteTaker);
        _notesWindow.Closed += (_, _) => _notesWindow = null;
        _notesWindow.Show();
    }

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
        _ = Media.StartAsync();
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
        ScreenShare.StopAll(null);
        Holo.Dispose();
        Fling.Dispose();
        Wake?.Dispose();
        Foreground.Dispose();
        Speaker.Dispose();
        AudioEndpoints.Dispose();
        HotKeys.Dispose();
        HoldKeys.Dispose();
        await Link.DisposeAsync();
    }
}
