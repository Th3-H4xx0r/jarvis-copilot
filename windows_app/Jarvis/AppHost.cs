using Jarvis.Core.Service;
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
using Jarvis.Update;
using Jarvis.Core.Update;
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
    public JcClientControl JcClient { get; private set; } = null!;
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
    public Unlock.PcUnlock Unlock { get; }
    public global::Jarvis.Remote.RemoteDesktop Remote { get; }
    public Stats.StatsService Stats { get; }
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
    public UpdateCoordinator Updates { get; }
    public UpdateCard UpdateCard { get; }

    /// What each global shortcut does; later tasks add theirs (orb, Holo Drop, record a call…).
    public Dictionary<ShortcutAction, Action> ShortcutHandlers { get; } = new();
    /// Tray commands the app handles; later tasks add theirs.
    public Dictionary<TrayCommand, Action> TrayHandlers { get; } = new();

    private readonly SessionCursor _cursor = new();
    private RecapWindow? _recap;
    private ChatTab? _chatTab;

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
        SettingsWindow.RegisterNative("pc-power", () => PcPowerPane.Build(PcPower, PowerRelay, Unlock));
        SettingsWindow.RegisterNative("shortcuts", () => ShortcutsPane.Build(Prefs, HotKeys, BindShortcuts));

        // ── Task 8: Power integrations and the phone-Face-ID admin flow (C6) ──
        Admin = new AdminRunner(Link);
        Unlock = new Unlock.PcUnlock(Link, Api, Admin);
        Stats = new Stats.StatsService(Api, State);
        Stats.SettingsChanged += () => Dispatcher.BeginInvoke(SyncStatsWindow);
        PcPowerPane.Extras.Add(StatsSettingsSection);
        Remote = new global::Jarvis.Remote.RemoteDesktop(Api, State, Admin, Link, () => Unlock.PinnedKey);
        // During a Remote Desktop session the island, the PC Stats window and any live share step aside.
        Remote.RemoteSessionChanged += remote => Dispatcher.BeginInvoke(() =>
        {
            if (remote)
            {
                IslandWindow.Hide();
                _statsWindow?.Close();
                ScreenShare?.StopAll("Remote Desktop is in use");
            }
            else
            {
                IslandWindow.Show();
                SyncStatsWindow();
            }
        });
        PcPowerPane.Extras.Add(() => global::Jarvis.Remote.RemoteDesktopSection.Build(Remote));
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
        VoiceTab.SettingsRequested += () => ShowSettings("talk");
        // The island's orbs: the ear (talk at once) and the Agents header (open Voice).
        IslandWindow.TalkRequested += () =>
        {
            if (!Voice.State.IsActive()) _ = Voice.StartConversationAsync("orb");
            Island.Open(IslandTab.Voice);
        };
        AgentsTab.TalkRequested += () => Island.SelectTab(IslandTab.Voice);

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
        var chatTab = new ChatTab(Chat, Island, () => IslandWindow);
        _chatTab = chatTab;
        IslandWindow.FilesDropped += files => { chatTab.AttachFiles(files); Island.Open(IslandTab.Chat, typing: true); };
        chatTab.SettingsRequested += () => ShowSettings();
        IslandWindow.Register(IslandTab.Chat, chatTab);
        Media = new MediaSessions();
        IslandWindow.Register(IslandTab.Music, new MusicTab(Media));
        Media.Changed += () => Dispatcher.BeginInvoke(() => IslandWindow.MusicPlaying = Media.Now?.IsPlaying == true);
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
        Holo.Changed += () => Dispatcher.BeginInvoke(() => IslandWindow.HoloAvailable = Holo.On);
        IslandWindow.HoloAvailable = Holo.On;
        // The island's hand button toggles the Orbit.
        IslandWindow.HoloRequested += () =>
        {
            if (_orbit is { IsLoaded: true } open) open.CloseOrbit();
            else OpenOrbit();
        };
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
        _updateShareBanner = UpdateBanner;
        shares.CurrentChanged += () =>
        {
            if (shares.Current is { } live) live.ViewersChanged += UpdateBanner;
            UpdateBanner();
        };
        State.ScreenSharesPoke += () => _ = ScreenShare.PollAsync();
        State.HelloReceived += () => _ = ScreenShare.PollAsync();
        State.GameModeChanged += m => { _ = ScreenShare.GameModeChangedAsync(m); UpdateBanner(); };
        var sharePoll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        sharePoll.Tick += (_, _) => { if (State.Connected) _ = ScreenShare.PollAsync(); };
        sharePoll.Start();

        // ── Task 19: in-app updates ──
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var version = AppVersion.Read(AppContext.BaseDirectory);
        var updater = new AppUpdater(Api, version, System.IO.Path.Combine(local, "Jarvis", "update"),
            System.IO.Path.Combine(local, "Programs", "Jarvis", "app"), System.IO.Path.Combine(local, "Programs", "Jarvis", "updater"),
            System.IO.Path.Combine(FileLog.Dir, "update.log"), Environment.ProcessId, UpdateCard.Launch);
        Updates = new UpdateCoordinator(updater.CheckAsync, version);
        UpdateCard = new UpdateCard(updater, Updates, Gate);
        State.AppUpdateSignal += topic => _ = Updates.SignalAsync(topic);
        var updatePoll = new DispatcherTimer { Interval = UpdateCoordinator.PollEvery };
        updatePoll.Tick += (_, _) => { if (State.Connected) _ = Updates.PollAsync(); };
        updatePoll.Start();

        // ── Task 14: the note-taker (RecordCall has no default chord, as on the Mac) ──
        NoteTaker = new NoteTaker(Api, () => State.ApiOrigin);
        ShortcutHandlers[ShortcutAction.RecordCall] = () => _ = NoteTaker.ToggleAsync();

        Tray = new TrayIcon(State, () => PcPower.Last?.KeepAwake ?? false, () => NoteTaker.Recording);

        // The app owns jc-client: start it now and whenever the link is down (unless it was stopped
        // on purpose); the tray's Restart / Stop drive it (they work while it's down).
        JcClient = new JcClientControl(local, HiddenProcess.RunAsync);
        TrayHandlers[TrayCommand.Restart] = () => _ = JcClient.RestartAsync();
        TrayHandlers[TrayCommand.StopService] = () => _ = JcClient.StopAsync();
        _ = JcClient.EnsureRunningAsync();
        var jcWatch = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        jcWatch.Tick += (_, _) => { if (!State.Connected) _ = JcClient.EnsureRunningAsync(); };
        jcWatch.Start();
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
        _updateShareBanner?.Invoke();   // never over a fullscreen game
    }

    private Action? _updateShareBanner;

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
        if (!Holo.FirewallNeeded)
            return Pane.Group(Pane.Section("Holo Drop"),
                Th.Text(Holo.On ? $"On. Drops are saved to {Holo.SaveFolder}." : "Off (Settings → Power integrations).", 13, "JcSetLabel", wrap: true));
        return Pane.Group(Pane.Section("Holo Drop"),
            Pane.Labeled("Let phones on your Wi-Fi send straight to this PC", Th.Button(HoloFirewall.Why, () => _ = Holo.AllowFirewallAsync()),
                "You approve with Face ID on your iPhone, then click Yes on Windows' prompt."));
    }

    private Stats.DashboardWindow? _statsWindow;
    private string? _statsMonitor;

    /// PC Stats' side-monitor window: open on the chosen monitor while the integration is on (and
    /// the monitor isn't "off"); closed otherwise. It never takes focus when it opens.
    private void SyncStatsWindow()
    {
        var monitor = Stats.Monitor;
        var want = Stats.On && !string.Equals(monitor, "off", StringComparison.OrdinalIgnoreCase);
        if (!want)
        {
            _statsWindow?.Close();
            _statsWindow = null;
            return;
        }
        if (_statsWindow == null)
        {
            _statsWindow = new Stats.DashboardWindow(Api, Stats, State, Prefs);
            _statsWindow.Closed += (_, _) => _statsWindow = null;
            _statsMonitor = null;
        }
        if (_statsMonitor != monitor)
        {
            _statsMonitor = monitor;
            _statsWindow.Place(monitor);
        }
    }

    /// Settings → PC power → PC Stats: which monitor the dashboard opens on, open it, and the sensor
    /// helper (a service; installing it asks Face ID on his iPhone, then Windows' Yes).
    private FrameworkElement StatsSettingsSection()
    {
        var monitors = new List<(string, string)> { ("", "Automatic (a side monitor)"), ("off", "Don't show it") };
        monitors.AddRange(Monitors.All().Select(m => (m.Name.Replace(@"\\.\", ""), m.Name.Replace(@"\\.\", "") + (m.Primary ? " (main)" : ""))));
        var note = Th.Text(Stats.On ? "" : "PC Stats is switched off (Integrations).", 12, "JcSetSecondary", wrap: true);
        var picker = Pane.Picker(monitors, Stats.Monitor, v => _ = SetStatsMonitorAsync(v, note));
        var helperInstalled = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\JarvisSensors") != null;
        var helper = helperInstalled
            ? (UIElement)Th.Row(8, Th.Text(Stats.HelperConnected ? "Running" : "Installed", 13, "JcSetSecondary"),
                Th.Button("Reinstall", () => _ = InstallSensorsAsync(note)))
            : Th.Button("Install", () => _ = InstallSensorsAsync(note), primary: true);
        return Pane.Group(Pane.Section("PC Stats"),
            Pane.Labeled("Show the dashboard on", picker),
            Pane.Labeled("Dashboard", Th.Button("Open", OpenStatsWindow)),
            Pane.Labeled("Sensor helper", helper, "Reads temperatures, fans, watts and frame rate. A system service; installing asks Face ID on your iPhone, then Windows' Yes."),
            note);
    }

    private async Task SetStatsMonitorAsync(string monitor, System.Windows.Controls.TextBlock note)
    {
        try
        {
            await Api.PostAsync("/api/power/pc-stats", new System.Text.Json.Nodes.JsonObject
            {
                ["settings"] = new System.Text.Json.Nodes.JsonObject { ["monitor"] = monitor }, ["client"] = "windows",
            }, TimeSpan.FromSeconds(10));
            await Stats.RefreshSettingsAsync();
            note.Text = "";
        }
        catch (Core.Http.ApiException e) { note.Text = "Couldn't change it: " + e.Error; }
    }

    private async Task InstallSensorsAsync(System.Windows.Controls.TextBlock note)
    {
        var exe = System.IO.Path.Combine(AppContext.BaseDirectory, "JarvisSensors.exe");
        if (!System.IO.File.Exists(exe)) { note.Text = "The sensor helper is missing from this build."; return; }
        var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
        var driver = Stats.DriverOn ? " --driver" : "";
        var result = await Admin.RunAsync($"\"{exe}\" --install {sid}{driver}", "Install the PC Stats sensor helper");
        note.Text = result.Message;
    }

    /// Settings → PC power's "Open dashboard": reopen it if he closed it.
    public void OpenStatsWindow()
    {
        _statsMonitor = null;
        SyncStatsWindow();
        _statsWindow?.Place(Stats.Monitor);
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
        IslandWindow.Refresh();
        if (Array.IndexOf(args, "--diag") is var i and >= 0 && i + 1 < args.Length) Diag(args[(i + 1)..]);
        Link.Start();
    }

    private static string DiagFile => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis", "diag.txt");

    /// A second launch's `--diag …`, for the running instance to pick up when poked.
    public static void QueueDiag(string[] args)
    {
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(DiagFile)!);
            System.IO.File.WriteAllLines(DiagFile, args);
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
    }

    public static string[]? TakeQueuedDiag()
    {
        try
        {
            if (!System.IO.File.Exists(DiagFile)) return null;
            var args = System.IO.File.ReadAllLines(DiagFile);
            System.IO.File.Delete(DiagFile);
            return args.Length > 0 ? args : null;
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { return null; }
    }

    /// Dev switches for desktop verification over the PC scripts (`Jarvis.exe --diag …`, also
    /// forwarded to the running instance): put the island in each state for a screenshot.
    public void Diag(string[] rest)
    {
        string Arg(int i) => rest.Length > i ? rest[i] : "";
        switch (rest[0])
        {
            case "open-tray-menu": Tray.OpenMenu(); break;
            case "island":
                Island.Pinned = Arg(2) != "unpinned";
                Island.Open(IslandTabs.Parse(Arg(1)) ?? IslandTab.Agents);
                break;
            case "fold": Island.Pinned = false; Island.Close(); break;
            case "unpin": Island.Pinned = false; break;
            case "limits": AgentsTab.ShowLimits = Arg(1) != "off"; Island.Pinned = true; Island.Open(IslandTab.Agents); break;
            case "demo":
                if (int.TryParse(Arg(1), out var n) && n >= 0 && n < DemoData.Steps.Count)
                    State.SetDemo(DemoData.Steps[n].Sessions, DemoData.Steps[n].Pending);
                break;
            case "end-demo": State.EndDemo(); break;
            case "voice-preview": VoiceTab.Preview(Arg(1) != "off"); Island.Pinned = true; Island.Open(IslandTab.Voice); break;
            case "chat-menu": Island.Pinned = true; Island.Open(IslandTab.Chat); Dispatcher.BeginInvoke(() => _chatTab?.ShowMenu(), DispatcherPriority.Background); break;
            case "slowmo": IslandWindow.TimeScale = double.TryParse(Arg(1), System.Globalization.CultureInfo.InvariantCulture, out var k) && k >= 1 ? k : 1; break;
            case "settings": ShowSettings(rest.Length > 1 ? rest[1] : null); break;
            case "settings-shot": Settings.SettingsWindow.Snapshot(State, Arg(1), Arg(2)); break;
            case "encode-bench": _ = Task.Run(() => Screen.EncodeBench.Run(Arg(1))); break;
            case "stats-board": _statsWindow?.ShowBoard(Arg(1)); break;   // switches without a click (no focus taken)
            case "orbit-shot":
                Ui.Snap.Save((FrameworkElement)new HoloOrbitWindow(Holo, HoloSender, null, Holo.Devices).Content, 400, 572, Arg(1));
                break;
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
    public void ShowIsland()
    {
        Island.Open(IslandTab.Agents);
        _ = Updates.ActivationAsync();
    }

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
