using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Http;
using Jarvis.Core.Model;

namespace Jarvis.Core.Screen;

/// One live share (capture + a WebRTC peer per viewer): built by the app's adapter.
public interface IShareSession
{
    string Id { get; }
    int Viewers { get; }
    /// Stops capture and every peer; `error` is the reason shown to viewers (null = plain stop).
    void Stop(string? error);
}

public interface IShareSessionFactory
{
    IShareSession Start(string id, string reason, bool recordReplay, IInputGate input);
}

/// Every input message passes here: dropped while a game is on (C3), so no synthetic input can
/// reach a game, even in the instant before the share is torn down.
public interface IInputGate
{
    bool TrySend(IInputSink sink, IReadOnlyList<InputEvent> inputs);
}

/// Finds this PC's shares and keeps them under the game guard. Nothing captures or encodes until
/// a share is ours, and nothing starts while game mode (or a background anti-cheat game) is on:
/// the share is stopped on the server with the refusal text instead. A fullscreen "game" gets a
/// short grace first (ShareGameGrace) so a flicker of the check neither refuses nor kills a share;
/// input is refused at once regardless. A share also never starts while the PC can't capture (his
/// session off the console after Remote Desktop): the phone is told why instead of waiting.
public sealed class ScreenShareService : IInputGate
{
    private readonly ApiClient _api;
    private readonly Func<string?> _deviceId;
    private readonly Func<GameMode> _mode;
    private readonly IShareSessionFactory _factory;
    private readonly Func<string?> _notReady;
    private readonly TimeProvider _time;
    private readonly ShareGameGrace _grace = new();
    private readonly Dictionary<string, IShareSession> _sessions = new();
    private readonly HashSet<string> _finished = new();
    private readonly object _lock = new();
    private ITimer? _graceTimer;
    private bool _deferred;
    private bool _polling;

    /// `notReady` gives the reason the PC can't capture right now (null when it can).
    public ScreenShareService(ApiClient api, Func<string?> deviceId, Func<GameMode> mode, IShareSessionFactory factory,
        Func<string?>? notReady = null, TimeProvider? time = null)
    {
        _api = api;
        _deviceId = deviceId;
        _mode = mode;
        _factory = factory;
        _notReady = notReady ?? (() => null);
        _time = time ?? TimeProvider.System;
    }

    public int Viewers { get { lock (_lock) return _sessions.Values.Sum(s => s.Viewers); } }
    public bool Capturing { get { lock (_lock) return _sessions.Count > 0; } }

    /// The look again that the end of a grace fires (tests await it).
    internal Task GraceCheck { get; private set; } = Task.CompletedTask;

    public async Task PollAsync()
    {
        var device = _deviceId();
        if (string.IsNullOrEmpty(device)) return;
        lock (_lock)
        {
            if (_polling) return;
            _polling = true;
        }
        try
        {
            JsonObject reply;
            try { reply = await _api.GetAsync(ShareSelection.ListPath(device), TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
            catch (ApiException) { return; }
            var mine = ShareSelection.Mine(reply, device);
            var ids = mine.Select(m => m.Id).ToHashSet();
            List<IShareSession> endedRemotely;
            lock (_lock)
            {
                endedRemotely = _sessions.Values.Where(s => !ids.Contains(s.Id)).ToList();
                foreach (var s in endedRemotely) { _sessions.Remove(s.Id); _finished.Add(s.Id); }
            }
            foreach (var s in endedRemotely) s.Stop(null);
            foreach (var (id, reason) in mine)
            {
                lock (_lock) { if (_sessions.ContainsKey(id) || _finished.Contains(id)) continue; }
                switch (Observe(_mode()))
                {
                    case ShareGameGrace.End end:
                        lock (_lock) _finished.Add(id);
                        await PostStop(id, end.Refusal).ConfigureAwait(false);
                        continue;
                    case ShareGameGrace.Wait wait:
                        // Not started, not refused: looked at again when the grace runs out (or the game ends).
                        lock (_lock) _deferred = true;
                        ArmGrace(wait.Left);
                        continue;
                }
                if (_notReady() is { } why)
                {
                    lock (_lock) _finished.Add(id);
                    await PostStop(id, why).ConfigureAwait(false);
                    continue;
                }
                var session = _factory.Start(id, reason, ShareSelection.RecordsReplay(reason), this);
                // (a session that failed while starting has already ended itself: don't keep it)
                lock (_lock) { if (!_finished.Contains(id)) _sessions[id] = session; }
            }
        }
        finally
        {
            lock (_lock) _polling = false;
        }
    }

    /// game_mode changed: a game (after its grace) or an anti-cheat game stops every share, saying
    /// why; the game ending picks up a share that was waiting on it.
    public async Task GameModeChangedAsync(GameMode m)
    {
        var verdict = Observe(m);
        switch (verdict)
        {
            case ShareGameGrace.Wait wait:
                ArmGrace(wait.Left);
                return;
            case ShareGameGrace.End end:
                DisarmGrace();
                List<IShareSession> live;
                lock (_lock)
                {
                    live = _sessions.Values.ToList();
                    _sessions.Clear();
                    foreach (var s in live) _finished.Add(s.Id);
                }
                foreach (var s in live)
                {
                    s.Stop(end.Refusal);
                    await PostStop(s.Id, end.Refusal).ConfigureAwait(false);
                }
                break;
            default:
                DisarmGrace();
                break;
        }
        bool deferred;
        lock (_lock) { deferred = _deferred; _deferred = false; }
        if (deferred) await PollAsync().ConfigureAwait(false);
    }

    /// A session ended on its own (its viewers left, capture failed).
    public void SessionEnded(string id)
    {
        lock (_lock)
        {
            _sessions.Remove(id);
            _finished.Add(id);
        }
    }

    /// A session couldn't capture (or lost capture): end it here and tell the phone why.
    public async Task SessionFailedAsync(string id, string why)
    {
        IShareSession? s;
        lock (_lock)
        {
            _sessions.Remove(id, out s);
            _finished.Add(id);
        }
        s?.Stop(why);
        await PostStop(id, why).ConfigureAwait(false);
    }

    public void StopAll(string? reason) => _ = StopAllAsync(reason);

    /// Stops every share; with a reason, the server (and so the phone) hears it too.
    public async Task StopAllAsync(string? reason)
    {
        List<IShareSession> live;
        lock (_lock)
        {
            live = _sessions.Values.ToList();
            _sessions.Clear();
            foreach (var s in live) _finished.Add(s.Id);
        }
        foreach (var s in live) s.Stop(reason);
        if (reason == null) return;
        foreach (var s in live) await PostStop(s.Id, reason).ConfigureAwait(false);
    }

    private ShareGameGrace.Verdict Observe(GameMode m)
    {
        lock (_lock) return _grace.Observe(m, _time.GetUtcNow());
    }

    private void ArmGrace(TimeSpan left)
    {
        lock (_lock)
        {
            _graceTimer?.Dispose();
            _graceTimer = _time.CreateTimer(_ => GraceCheck = GameModeChangedAsync(_mode()), null, left, Timeout.InfiniteTimeSpan);
        }
    }

    private void DisarmGrace()
    {
        lock (_lock)
        {
            _graceTimer?.Dispose();
            _graceTimer = null;
        }
    }

    public bool TrySend(IInputSink sink, IReadOnlyList<InputEvent> inputs)
    {
        if (ComputerControlGuard.Refusal(_mode()) != null) return false;
        sink.Send(inputs);
        return true;
    }

    private async Task PostStop(string id, string error)
    {
        try { await _api.PostAsync(ShareSelection.StopPath(id), new JsonObject { ["error"] = error }, TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
        catch (ApiException) { }
    }
}
