using System.Net;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Gaming;
using Jarvis.Core.Link;
using Jarvis.Core.Model;

namespace Jarvis.Core.Holo;

/// The Windows adapters HoloDropService drives.
public sealed record HoloPorts(
    IHoloReceiver Receiver, IHoloCards Cards, IHoloBeacons Beacons, IHoloScreenReport Screen, IHoloBleBeacon Ble,
    IHoloFirewall Firewall);

public sealed class HoloDropOptions
{
    /// Where Save writes (default `%USERPROFILE%\Downloads\Holo Drop`).
    public string SaveFolder { get; init; } = HoloLander.DefaultSaveFolder;
    /// Where downloads, LAN uploads and the inbox live (`HoloDrop-*` folders).
    public string TempRoot { get; init; } = HoloTemp.DefaultRoot;
    /// The LAN receiver's bind address (the PC: any; tests: loopback).
    public IPAddress BindAddress { get; init; } = IPAddress.Any;
    public Func<string?> LanAddress { get; init; } = HoloLanAddress.Current;
    public TimeProvider Time { get; init; } = TimeProvider.System;
    public Func<GameMode> GameMode { get; init; } = () => Model.GameMode.Off;
    /// The paired device id from jc-client's hello (the BLE beacon's name).
    public Func<string?> DeviceId { get; init; } = () => null;
    public AdminRunner? Admin { get; init; }
    /// The app's exe, which the firewall rule allows.
    public string ExePath { get; init; } = Environment.ProcessPath ?? "Jarvis.exe";
    /// The last known Power switch (unknown counts as on).
    public bool InitialOn { get; init; } = true;
    /// Runs gate calls on the UI thread. Must run the action before returning (Dispatcher.Invoke),
    /// so a drop's "open" knows whether it ran.
    public Action<Action> Dispatch { get; init; } = a => a();
}

/// Holo Drop on the PC (port of `HoloDrop.swift`'s receive side): lands drops from his other
/// devices (bridge `holo_drop` frames, `/pending` on hello and wake, or straight over the LAN)
/// as arrival cards through the PresentationGate; answers screen-map requests and plays the
/// direction beacons. Everything follows the Power switch (`/api/power` row "holo-drop"): off
/// stops the LAN receiver, the BLE beacon and the beacons, and drops are ignored.
///
/// The PC never says it moved: a desktop's spot stays put, so neither wake nor a network change
/// calls `/moved` (the Mac's HoloMovedWatch has no counterpart here).
public sealed class HoloDropService : IDisposable
{
    public static readonly TimeSpan LanAdvertEvery = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan LanTokenLife = TimeSpan.FromMinutes(15);
    /// How long an arrival card stays unless the pointer is on it.
    public static readonly TimeSpan CardStays = TimeSpan.FromSeconds(14);

    private readonly HoloDropApi _api;
    private readonly PresentationGate _gate;
    private readonly HoloPorts _ports;
    private readonly HoloDropOptions _opt;
    private readonly HoloLanServer _lan;
    private readonly HoloLander _lander;
    private readonly object _lock = new();
    private readonly List<string> _handled = new();
    private readonly List<string> _shownLandings = new();
    private readonly Dictionary<string, string> _awaiting = new();
    private readonly List<Task> _inFlight = new();
    private readonly SemaphoreSlim _sync = new(1, 1);
    private IReadOnlyList<HoloDevice> _devices = Array.Empty<HoloDevice>();
    private ITimer? _advertTimer;
    private bool _on;
    private bool _started;
    private bool _disposed;

    public HoloDropService(HoloDropApi api, PresentationGate gate, HoloPorts ports, HoloDropOptions? options = null)
    {
        _api = api;
        _gate = gate;
        _ports = ports;
        _opt = options ?? new HoloDropOptions();
        _on = _opt.InitialOn;
        _lan = new HoloLanServer(_opt.Time, _opt.TempRoot) { OnDrop = LandDirectAsync };
        _lander = new HoloLander(_opt.SaveFolder, _opt.TempRoot, _opt.Time);
    }

    public bool On { get { lock (_lock) return _on; } }
    /// The firewall rule is missing: General shows "Let Holo Drop receive on your network".
    public bool FirewallNeeded { get; private set; }
    public int? LanPort => _lan.Port;
    public string SaveFolder => _lander.SaveFolder;
    public IReadOnlyList<HoloDevice> Devices { get { lock (_lock) return _devices; } }

    /// On/off, the firewall state or the device list changed.
    public event Action? Changed;

    /// A landing for a drop this PC sent: the Orbit shows it when it's still waiting there
    /// (answers true); else it's a toast.
    public Func<string, string, bool>? ShowInOrbit { get; set; }

    // MARK: lifecycle

    /// jc-client said hello: the server is reachable through its proxy now.
    public async Task ServerReadyAsync()
    {
        var first = false;
        lock (_lock)
        {
            if (!_started) { _started = true; first = true; }
        }
        if (first) _ = Task.Run(() => HoloTemp.Sweep(_opt.TempRoot));
        await RefreshPowerAsync().ConfigureAwait(false);
        await SyncAsync().ConfigureAwait(false);
        if (!On) return;
        await LoadDevicesAsync().ConfigureAwait(false);
        await FetchPendingAsync().ConfigureAwait(false);
        await AdvertiseAsync().ConfigureAwait(false);
    }

    /// The server published `power`: read the switch now.
    public Task PowerTopicAsync() => RefreshPowerAsync();

    /// The PC woke: re-read the switch, pick up what arrived meanwhile, re-advertise. No `/moved`.
    public async Task DidWakeAsync()
    {
        await RefreshPowerAsync().ConfigureAwait(false);
        await FetchPendingAsync().ConfigureAwait(false);
        await AdvertiseAsync().ConfigureAwait(false);
    }

    /// A network came up or changed: re-advertise the LAN address. No `/moved`.
    public Task NetworkChangedAsync() => AdvertiseAsync();

    public async Task RefreshPowerAsync()
    {
        bool? enabled;
        try { enabled = await _api.PowerEnabledAsync().ConfigureAwait(false); }
        catch (HoloFailure) { return; }   // unknown: keep what we had
        await SetOnAsync(enabled ?? false).ConfigureAwait(false);   // no Holo Drop row: this server has none
    }

    private async Task SetOnAsync(bool value)
    {
        bool changed;
        lock (_lock)
        {
            changed = _on != value;
            _on = value;
        }
        await SyncAsync().ConfigureAwait(false);
        if (changed) Changed?.Invoke();
    }

    private async Task SyncAsync()
    {
        await _sync.WaitAsync().ConfigureAwait(false);
        try
        {
            bool started, on;
            lock (_lock) { started = _started; on = _on; }
            if (!started || _disposed) return;
            if (on) StartServices(); else await StopServicesAsync().ConfigureAwait(false);
        }
        finally { _sync.Release(); }
    }

    private void StartServices()
    {
        if (_opt.DeviceId() is { Length: > 0 } id) _ports.Ble.Start(id);
        if (_lan.Running) return;
        var needed = !_ports.Firewall.RuleExists();
        if (needed != FirewallNeeded)
        {
            FirewallNeeded = needed;
            Changed?.Invoke();
        }
        if (needed) return;   // binds only once the rule exists
        _lan.Start(_opt.BindAddress);
        _advertTimer ??= _opt.Time.CreateTimer(_ => Track(AdvertiseAsync()), null, LanAdvertEvery, LanAdvertEvery);
        Track(AdvertiseAsync());
    }

    private async Task StopServicesAsync()
    {
        _ports.Ble.Stop();
        _ports.Beacons.Stop();
        _advertTimer?.Dispose();
        _advertTimer = null;
        if (_lan.Running)
        {
            _lan.Stop();
            await _api.ClearLanAsync().ConfigureAwait(false);
        }
    }

    /// The firewall button: adds the rule through AdminRunner (Face ID on his phone, then UAC),
    /// then starts the LAN receiver if the rule is there now.
    public async Task<AdminResult> AllowFirewallAsync()
    {
        if (_opt.Admin is not { } admin) return new AdminResult(false, "error", "Jarvis isn't connected to jc-client");
        var result = await admin.RunAsync(HoloFirewall.AddRuleCommand(_opt.ExePath), HoloFirewall.Why).ConfigureAwait(false);
        if (result.Ok) await SyncAsync().ConfigureAwait(false);
        return result;
    }

    /// Checks the rule again (an elevated netsh can finish after jc-client said "approved").
    public Task RecheckFirewallAsync() => SyncAsync();

    /// Tell Jarvis where this PC listens on the LAN, with a fresh token.
    private async Task AdvertiseAsync()
    {
        bool ok;
        lock (_lock) ok = _on && _started && !_disposed;
        if (!ok || _lan.Port is not { } port || _opt.LanAddress() is not { Length: > 0 } ip) return;
        var token = _lan.NewToken(LanTokenLife);
        var expires = _opt.Time.GetUtcNow() + LanTokenLife;
        try
        {
            await _api.AdvertiseLanAsync($"http://{ip}:{port}", token, expires).ConfigureAwait(false);
        }
        catch (HoloFailure f) when (f.Kind == HoloFailureKind.Off)
        {
            await SetOnAsync(false).ConfigureAwait(false);
        }
        catch (HoloFailure) { }
    }

    // MARK: frames from the server

    /// A `holo_drop` frame jc-client passed on (`{type: "holo_drop", event, …}`).
    public void Handle(JsonObject frame) => Track(HandleAsync(frame));

    public async Task HandleAsync(JsonObject frame)
    {
        switch (J.S(frame["event"]))
        {
            case "drop":
                if (!On || HoloDropRecord.FromJson(J.Obj(frame["drop"])) is not { } drop) return;
                await ReceiveAsync(drop).ConfigureAwait(false);
                break;
            case "landed":
                Landed(J.Obj(frame["drop"]), J.StrOrNull(frame["error"]));
                break;
            case "screen_request":
                var request = J.S(frame["request"]);
                if (!On || request.Length == 0) return;
                var s = _ports.Screen.Current();
                await _api.AnswerScreenAsync(request, HoloWire.ScreenReport(s.Width, s.Height, s.Scale, s.Windows)).ConfigureAwait(false);
                break;
            case "beacon":
                if (!On || _opt.GameMode().On) return;   // nothing plays or flashes over a game
                var nonce = J.S(frame["nonce"]);
                switch (J.S(frame["mode"]))
                {
                    case "chirp": _ports.Beacons.Chirp(nonce); break;
                    case "flash": _ports.Beacons.Flash(nonce); break;
                    case "stop": _ports.Beacons.Stop(); break;
                }
                break;
        }
    }

    private async Task FetchPendingAsync()
    {
        if (!On) return;
        IReadOnlyList<HoloDropRecord> drops;
        try { drops = await _api.PendingAsync().ConfigureAwait(false); }
        catch (HoloFailure f) when (f.Kind == HoloFailureKind.Off) { await SetOnAsync(false).ConfigureAwait(false); return; }
        catch (HoloFailure) { return; }
        foreach (var d in drops) await ReceiveAsync(d).ConfigureAwait(false);
    }

    private async Task LoadDevicesAsync()
    {
        try
        {
            var list = await _api.DevicesAsync().ConfigureAwait(false);
            lock (_lock) _devices = list;
            Changed?.Invoke();
        }
        catch (HoloFailure f) when (f.Kind == HoloFailureKind.Off) { await SetOnAsync(false).ConfigureAwait(false); }
        catch (HoloFailure) { }
    }

    private async Task ReceiveAsync(HoloDropRecord drop)
    {
        if (drop.Id.Length == 0 || !Remember(drop.Id)) return;
        var (outcome, error) = await LandAsync(drop, SenderName(drop), null, fromServer: true).ConfigureAwait(false);
        await _api.LandedAsync(drop.Id, outcome, error).ConfigureAwait(false);
    }

    /// A drop that came straight over the LAN: lands the same way (and is reported to Jarvis too
    /// when the sender already recorded it there).
    private async Task<HoloOutcome> LandDirectAsync(JsonObject fields, string? file, JsonObject inline)
    {
        await RefreshPowerAsync().ConfigureAwait(false);   // the live switch, not the last poll
        if (!On) return HoloOutcome.Failed;
        var json = (JsonObject)fields.DeepClone();
        foreach (var (k, v) in inline) json[k] = v?.DeepClone();
        json["created"] ??= _opt.Time.GetUtcNow().ToUnixTimeMilliseconds() / 1000.0;
        if (HoloDropRecord.FromJson(json) is not { } drop) return HoloOutcome.Failed;
        if (drop.Id.Length > 0 && !Remember(drop.Id)) return HoloOutcome.Shown;
        var (outcome, error) = await LandAsync(drop, SenderName(drop), file, fromServer: false).ConfigureAwait(false);
        if (drop.Id.Length > 0) await _api.LandedAsync(drop.Id, outcome, error).ConfigureAwait(false);
        return outcome;
    }

    /// Lands one drop (port of `HoloReceiver.land`). The card goes through the gate at once;
    /// fetching, saving and copying happen regardless of it, but "open" waits until the gate
    /// allows it, so nothing launches over a game. An open that has to wait isn't counted in the
    /// outcome (it hasn't happened yet).
    private async Task<(HoloOutcome, string?)> LandAsync(HoloDropRecord drop, string fromName, string? file, bool fromServer)
    {
        var action = drop.Action ?? HoloAction.Open;
        var plan = HoloLanding.Plan(drop, action, HoloLanding.IsExecutable(drop.Name, drop.Mime));
        var card = new HoloArrival(drop, fromName, _opt.Time.GetUtcNow())
        {
            State = plan.Fetch ? HoloArrivalState.Receiving : HoloArrivalState.Ready,
        };
        var key = drop.Id.Length > 0 ? drop.Id : Guid.NewGuid().ToString("N");
        Present("holo:" + key, () => _ports.Cards.Show(card));

        string? local = null;
        if (plan.Fetch)
        {
            try
            {
                var tmp = file ?? (fromServer
                    ? await _api.ContentAsync(drop.Id, _opt.TempRoot).ConfigureAwait(false)
                    : throw new HoloFailure(HoloFailureKind.NotReachable));
                local = _lander.IntoInbox(tmp, drop);
                card.LocalFile = local;
                // Decide on what's actually on disk now, not the name the sender gave.
                if (plan.Open && HoloLander.UnsafeToOpen(local)) plan = plan with { Open = false, OpenHeld = true };
            }
            catch (Exception e) when (e is HoloFailure or IOException or UnauthorizedAccessException)
            {
                card.State = HoloArrivalState.Failed;
                card.Error = e.Message;
                card.Outcome = HoloOutcome.Failed;
                card.Notify();
                return (HoloOutcome.Failed, e.Message);
            }
        }
        card.State = HoloArrivalState.Ready;
        bool saved = false, opened = false, copied = false;
        if (plan.Save && _lander.Save(drop, local) is { } u)
        {
            saved = true;
            card.SavedFile = u;
            if (local != null) { local = u; card.LocalFile = u; }
        }
        if (plan.Open && (local ?? drop.WebUrl?.AbsoluteUri) is { } target)
        {
            var ran = false;
            var ok = false;
            Present("holo-open:" + key, () => { ran = true; ok = _ports.Receiver.Open(target); });
            opened = ran && ok;
        }
        if (plan.OpenHeld) card.Note = "Click Open to open it";
        if (plan.Copy)
        {
            copied = _ports.Receiver.Copy(drop, local);
            card.Copied = copied;
        }
        if (plan.Show) card.Expanded = true;
        var outcome = HoloOutcome.From(saved, opened, copied, shown: true);
        card.Outcome = outcome;
        card.Notify();
        return (outcome, null);
    }

    // MARK: the card's buttons

    public bool OpenFromCard(HoloArrival card)
    {
        if ((card.SavedFile ?? card.LocalFile) is { } f) return _ports.Receiver.Open(f);
        if (card.Drop.WebUrl is { } u) return _ports.Receiver.Open(u.AbsoluteUri);
        // Any other link opens only from here (never unprompted).
        if (card.Drop.Kind == HoloKind.Link && Uri.TryCreate(card.Drop.Url, UriKind.Absolute, out _)) return _ports.Receiver.Open(card.Drop.Url);
        return false;
    }

    /// Saves now (or answers where it's saved already, for the adapter to reveal it).
    public string? SaveFromCard(HoloArrival card)
    {
        if (card.SavedFile != null) return card.SavedFile;
        if (_lander.Save(card.Drop, card.LocalFile) is not { } u) return null;
        card.SavedFile = u;
        if (card.LocalFile != null) card.LocalFile = u;
        card.Notify();
        return u;
    }

    public bool CopyFromCard(HoloArrival card)
    {
        card.Copied = _ports.Receiver.Copy(card.Drop, card.SavedFile ?? card.LocalFile);
        card.Notify();
        return card.Copied;
    }

    // MARK: drops this PC sent

    /// The Orbit sent something: direct drops have answered already (their landed frame isn't
    /// shown again); server drops wait for their landed frame under `deviceName`.
    public void Track(HoloSent sent, string deviceName)
    {
        foreach (var id in sent.DirectIds) MarkShown(id);
        lock (_lock) foreach (var id in sent.Ids) _awaiting[id] = deviceName;
    }

    /// True the first time a landing is shown (the Orbit's own wait uses it too).
    public bool MarkShown(string id)
    {
        lock (_lock)
        {
            if (_shownLandings.Contains(id)) return false;
            _shownLandings.Add(id);
            if (_shownLandings.Count > 400) _shownLandings.RemoveRange(0, 200);
            return true;
        }
    }

    /// A drop this PC sent has landed (the server sends `landed` only to the sender): shown in
    /// the Orbit when it's still waiting there, else as a toast, once however late.
    private void Landed(JsonObject json, string? error)
    {
        if (HoloDropRecord.FromJson(json) is not { } drop || drop.Id.Length == 0 || !MarkShown(drop.Id)) return;
        string name;
        lock (_lock)
        {
            name = _awaiting.Remove(drop.Id, out var n) ? n
                : _devices.FirstOrDefault(d => d.Id == drop.Target)?.Name ?? "your device";
        }
        var why = !string.IsNullOrEmpty(error) ? error : J.S(json["error"]);
        var line = HoloDropRecord.LandedLine(name, drop.Outcome, why);
        if (ShowInOrbit?.Invoke(drop.Id, line) == true) return;
        var failed = drop.Outcome == HoloOutcome.Failed.Wire;
        Present("holo-landed:" + drop.Id, () => _ports.Cards.Toast(line, failed));
    }

    // MARK: helpers

    private void Present(string key, Action show) => _opt.Dispatch(() => _gate.Present(key, show));

    private bool Remember(string id)
    {
        lock (_lock)
        {
            if (_handled.Contains(id)) return false;
            _handled.Add(id);
            if (_handled.Count > 200) _handled.RemoveRange(0, 100);
            return true;
        }
    }

    private string SenderName(HoloDropRecord drop)
    {
        if (drop.FromName.Length > 0) return drop.FromName;
        lock (_lock) return _devices.FirstOrDefault(d => d.Id == drop.From)?.Name ?? "your device";
    }

    private void Track(Task t)
    {
        lock (_inFlight)
        {
            _inFlight.RemoveAll(x => x.IsCompleted);
            _inFlight.Add(t);
        }
    }

    /// Waits for every fire-and-forget piece of work (frames, adverts) started so far.
    public async Task WhenIdleAsync()
    {
        while (true)
        {
            Task[] pending;
            lock (_inFlight) pending = _inFlight.Where(t => !t.IsCompleted).ToArray();
            if (pending.Length == 0) return;
            try { await Task.WhenAll(pending).ConfigureAwait(false); }
            catch (Exception) { }
        }
    }

    public void Dispose()
    {
        lock (_lock) _disposed = true;
        _advertTimer?.Dispose();
        _advertTimer = null;
        _lan.Dispose();
    }
}
