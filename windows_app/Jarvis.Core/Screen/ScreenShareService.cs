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
/// the share is stopped on the server with the refusal text instead.
public sealed class ScreenShareService : IInputGate
{
    private readonly ApiClient _api;
    private readonly Func<string?> _deviceId;
    private readonly Func<GameMode> _mode;
    private readonly IShareSessionFactory _factory;
    private readonly Dictionary<string, IShareSession> _sessions = new();
    private readonly HashSet<string> _finished = new();
    private readonly object _lock = new();
    private bool _polling;

    public ScreenShareService(ApiClient api, Func<string?> deviceId, Func<GameMode> mode, IShareSessionFactory factory)
    {
        _api = api;
        _deviceId = deviceId;
        _mode = mode;
        _factory = factory;
    }

    public int Viewers { get { lock (_lock) return _sessions.Values.Sum(s => s.Viewers); } }
    public bool Capturing { get { lock (_lock) return _sessions.Count > 0; } }

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
                if (ComputerControlGuard.Refusal(_mode()) is { } refusal)
                {
                    lock (_lock) _finished.Add(id);
                    await PostStop(id, refusal).ConfigureAwait(false);
                    continue;
                }
                var session = _factory.Start(id, reason, ShareSelection.RecordsReplay(reason), this);
                lock (_lock) _sessions[id] = session;
            }
        }
        finally
        {
            lock (_lock) _polling = false;
        }
    }

    /// game_mode turned on (or anti-cheat started) mid-share: stop everything, say why.
    public async Task GameModeChangedAsync(GameMode m)
    {
        if (ComputerControlGuard.Refusal(m) is not { } refusal) return;
        List<IShareSession> live;
        lock (_lock)
        {
            live = _sessions.Values.ToList();
            _sessions.Clear();
            foreach (var s in live) _finished.Add(s.Id);
        }
        foreach (var s in live)
        {
            s.Stop(refusal);
            await PostStop(s.Id, refusal).ConfigureAwait(false);
        }
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

    public void StopAll(string? reason)
    {
        List<IShareSession> live;
        lock (_lock)
        {
            live = _sessions.Values.ToList();
            _sessions.Clear();
            foreach (var s in live) _finished.Add(s.Id);
        }
        foreach (var s in live) s.Stop(reason);
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
