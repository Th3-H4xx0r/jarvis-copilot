using System.Text.Json.Nodes;
using Jarvis.Core.Link;
using Jarvis.Core.Model;

namespace Jarvis.Core.State;

/// Everything the island, tray and Settings show, fed by jc-client's pushes (port of the Mac's
/// AppModel). Also notices the moments that matter: a session that starts waiting on you,
/// finishes or fails. Not thread-safe: the WPF Dispatcher is its only caller.
public sealed class AppState
{
    /// The server pushes the app subscribes to.
    public static readonly IReadOnlyDictionary<string, int> Topics = new Dictionary<string, int>
    {
        ["harness_jobs"] = 0, ["app_update"] = 0, ["screen_shares"] = 0, ["power"] = 0,
    };

    private static readonly TimeSpan FlashFor = TimeSpan.FromSeconds(5);

    private readonly IJcLink _link;
    private readonly TimeProvider _time;
    private readonly HashSet<string> _spokenJobs = new();
    private Dictionary<string, SessionState> _lastStates = new();
    private ITimer? _flashTimer;
    private ITimer? _jobsPrune;

    public AppState(IJcLink link, TimeProvider? time = null)
    {
        _link = link;
        _time = time ?? TimeProvider.System;
    }

    public bool Connected { get; private set; }
    public string? ApiOrigin { get; private set; }
    /// This PC's paired device id (the server's); null until a hello carries one.
    public string? DeviceId { get; private set; }
    public string? DeviceName { get; private set; }
    public string Platform { get; private set; } = "";
    public bool ApprovalsOn { get; private set; }
    public bool InstructionsOn { get; private set; }
    public IReadOnlyList<AgentSession> Sessions { get; private set; } = Array.Empty<AgentSession>();
    public IReadOnlyList<PendingRequest> Pending { get; private set; } = Array.Empty<PendingRequest>();
    public PlanUsage? Usage { get; private set; }
    public PlanUsage? CodexUsage { get; private set; }
    public IReadOnlyList<HarnessJob> Jobs { get; private set; } = Array.Empty<HarnessJob>();
    public IReadOnlyList<MovedSession> OnServer { get; private set; } = Array.Empty<MovedSession>();
    /// The session that just finished or failed, shown for 5 s.
    public AgentSession? Flash { get; private set; }
    public Roster? Roster { get; private set; }
    public GameMode GameMode { get; private set; } = GameMode.Off;
    /// While a demo runs, pushes from jc-client are ignored.
    public bool DemoActive { get; private set; }

    public AgentSession? Lead => Sessions.FirstOrDefault(s => s.State != SessionState.Idle);
    public int WaitingCount => Math.Max(Pending.Count, Sessions.Count(s => s.State.Urgency() == 0));
    public int WorkingCount =>
        Sessions.Count(s => s.State is SessionState.Working or SessionState.Thinking) + Jobs.Count(j => j.Running);
    public OrbMood Mood => Pending.Count == 0 ? (Lead?.State.Mood() ?? OrbMood.Idle) : OrbMood.Waiting;

    public PendingRequest? PendingFor(AgentSession s) =>
        Pending.FirstOrDefault(p => p.Fingerprint == s.PendingFingerprint) ?? Pending.FirstOrDefault(p => p.Key == s.Key);

    public event Action? Changed;
    public event Action<Moment, AgentSession?>? MomentRaised;
    /// Jarvis asked for a tab (the `jarvis_island` skill): tab, chat draft.
    public event Action<string, string?>? IslandRequested;
    public event Action<JsonObject>? HoloFrame;
    /// null = jc-client said hello (the server is known now); else the `app_update` topic data.
    public event Action<JsonObject?>? AppUpdateSignal;
    public event Action? ScreenSharesPoke;
    public event Action? PowerTopic;
    public event Action<HarnessJob>? Speak;
    public event Action<GameMode>? GameModeChanged;
    /// Every hello (Holo Drop's ServerReady, the screen-share poll, the OTA check hang off it).
    public event Action? HelloReceived;

    // ── link ───────────────────────────────────────────────────────────

    public void OnConnection(bool up)
    {
        Connected = up;
        if (up)
        {
            var topics = new JsonObject();
            foreach (var (k, v) in Topics) topics[k] = v;
            _ = _link.RequestAsync(new JsonObject { ["type"] = "subscribe", ["topics"] = topics });
            _ = RefreshRosterAsync();
        }
        Changed?.Invoke();
    }

    public void Handle(JsonObject msg)
    {
        if (DemoActive) return;
        switch (J.S(msg["type"]))
        {
            case "hello":
                ApiOrigin = J.StrOrNull(msg["api"]) is { Length: > 0 } api ? api : null;
                if (J.StrOrNull(msg["device_id"]) is { Length: > 0 } id) DeviceId = id;
                if (J.StrOrNull(msg["device_name"]) is { Length: > 0 } name) DeviceName = name;
                Platform = J.S(msg["platform"]);
                ApprovalsOn = J.B(msg["approvals"]);
                InstructionsOn = J.B(msg["instructions"]);
                ApplySessions(J.Arr(msg["sessions"]), announce: false);
                Pending = ParsePending(msg["pending"]);
                if (PlanUsage.FromJson(new JsonObject { ["rate_limits"] = msg["usage"]?.DeepClone() ?? new JsonObject() }) is { } u) Usage = u;
                if (msg["usage_codex"] is JsonObject codex && PlanUsage.FromJson(codex) is { } cu) CodexUsage = cu;
                OnServer = J.Arr(msg["moved"]).Select(MovedSession.FromJson).ToList();
                SetGameMode(GameMode.FromJson(msg["game_mode"]));
                AppUpdateSignal?.Invoke(null);
                HelloReceived?.Invoke();
                break;
            case "game_mode":
                SetGameMode(GameMode.FromJson(msg));
                break;
            case "moved":
                OnServer = J.Arr(msg["sessions"]).Select(MovedSession.FromJson).ToList();
                break;
            case "sessions":
                ApplySessions(J.Arr(msg["sessions"]), announce: true);
                break;
            case "pending":
            {
                var next = ParsePending(msg["pending"]);
                var fresh = next.Any(p => Pending.All(q => q.Fingerprint != p.Fingerprint));
                Pending = next;
                if (fresh) MomentRaised?.Invoke(Moment.NeedsYou, Sessions.FirstOrDefault(s => next.Any(p => p.Key == s.Key)));
                break;
            }
            case "usage":
                if (PlanUsage.FromJson(msg) is { } usage)
                {
                    if (J.S(msg["agent"]) == "codex") CodexUsage = usage; else Usage = usage;
                }
                break;
            case "island":
                IslandRequested?.Invoke(J.S(msg["tab"], "agents"), J.StrOrNull(msg["text"]));
                break;
            case "holo_drop":
                HoloFrame?.Invoke(msg);
                break;
            case "config":
                ApprovalsOn = J.B(msg["approvals"]);
                InstructionsOn = J.B(msg["instructions"]);
                break;
            case "topic":
            {
                var data = J.Obj(msg["data"]);
                switch (J.S(msg["topic"]))
                {
                    case "harness_jobs":
                        ApplyJobs(J.Arr(data["jobs"]));
                        if (data["speak"] is JsonObject speak) SpeakOnce(HarnessJob.FromJson(speak));
                        break;
                    case "app_update":
                        AppUpdateSignal?.Invoke(data);
                        break;
                    case "screen_shares":
                        ScreenSharesPoke?.Invoke();
                        break;
                    case "power":
                        PowerTopic?.Invoke();
                        break;
                }
                break;
            }
            default:
                return;
        }
        Changed?.Invoke();
    }

    private static IReadOnlyList<PendingRequest> ParsePending(JsonNode? n) =>
        J.Arr(n).Select(PendingRequest.FromJson).OfType<PendingRequest>().ToList();

    private void SetGameMode(GameMode m)
    {
        if (m == GameMode) return;
        GameMode = m;
        GameModeChanged?.Invoke(m);
    }

    /// Replace the sessions (also used by the demo).
    public void ApplySessions(IEnumerable<JsonObject> raw, bool announce)
    {
        var next = AgentSession.Sorted(raw.Select(AgentSession.FromJson));
        if (announce)
        {
            foreach (var s in next)
            {
                SessionState? before = _lastStates.TryGetValue(s.Key, out var b) ? b : null;
                if (before == s.State) continue;
                switch (s.State)
                {
                    case SessionState.Approval or SessionState.Question:
                        // The arbiter's own "pending" push announces relayed requests.
                        if (Pending.Count == 0) MomentRaised?.Invoke(Moment.NeedsYou, s);
                        break;
                    case SessionState.Finished:
                        ShowFlash(s);
                        MomentRaised?.Invoke(Moment.Finished, s);
                        break;
                    case SessionState.Error:
                        ShowFlash(s);
                        MomentRaised?.Invoke(Moment.Failed, s);
                        break;
                    case SessionState.Thinking when before == null || before == SessionState.Idle:
                        MomentRaised?.Invoke(Moment.Started, s);
                        break;
                }
            }
        }
        _lastStates = next.GroupBy(s => s.Key).ToDictionary(g => g.Key, g => g.First().State);
        Sessions = next;
    }

    /// The feed is the whole list each time. An ended job leaves after HarnessJob.ShownFor.
    private void ApplyJobs(IEnumerable<JsonObject> raw)
    {
        var now = _time.GetUtcNow();
        Jobs = raw.Select(HarnessJob.FromJson).Where(j => j.Id.Length > 0 && !j.Expired(now)).ToList();
        _jobsPrune?.Dispose();
        _jobsPrune = null;
        var next = Jobs.Where(j => j.CompletedAt != null).Select(j => j.CompletedAt!.Value + HarnessJob.ShownFor).DefaultIfEmpty().Min();
        if (next == default) return;
        var wait = next - now + TimeSpan.FromSeconds(1);
        if (wait < TimeSpan.FromSeconds(1)) wait = TimeSpan.FromSeconds(1);
        _jobsPrune = _time.CreateTimer(_ =>
        {
            var at = _time.GetUtcNow();
            var left = Jobs.Where(j => !j.Expired(at)).ToList();
            if (left.Count != Jobs.Count) { Jobs = left; Changed?.Invoke(); }
        }, null, wait, Timeout.InfiniteTimeSpan);
    }

    private void SpeakOnce(HarnessJob job)
    {
        if (job.Id.Length == 0 || job.Result.Length == 0 || !_spokenJobs.Add(job.Id)) return;
        Speak?.Invoke(job);
    }

    /// The Agents tab's Read aloud.
    public void ReadAloud(HarnessJob job)
    {
        if (job.Result.Length > 0) Speak?.Invoke(job);
    }

    private void ShowFlash(AgentSession s)
    {
        Flash = s;
        _flashTimer?.Dispose();
        _flashTimer = _time.CreateTimer(_ =>
        {
            Flash = null;
            _flashTimer?.Dispose();
            _flashTimer = null;
            Changed?.Invoke();
        }, null, FlashFor, Timeout.InfiniteTimeSpan);
    }

    // ── actions ────────────────────────────────────────────────────────

    public async Task<bool> DecideAsync(PendingRequest p, string decision, string? message = null, JsonObject? answers = null)
    {
        var body = new JsonObject { ["type"] = "decide", ["fingerprint"] = p.Fingerprint, ["decision"] = decision };
        if (message != null) body["message"] = message;
        if (answers != null) body["answers"] = answers.DeepClone();
        Pending = Pending.Where(x => x.Fingerprint != p.Fingerprint).ToList();
        Changed?.Invoke();
        var reply = await _link.RequestAsync(body);
        return J.B(reply["ok"]);
    }

    /// Bring a session that moved to the server back to this PC.
    public void BringBack(string ckey)
    {
        OnServer = OnServer.Where(m => m.Ckey != ckey).ToList();
        Changed?.Invoke();
        _ = _link.RequestAsync(new JsonObject { ["type"] = "agent_continue_mac", ["ckey"] = ckey });
    }

    public async Task RefreshRosterAsync()
    {
        var reply = await _link.RequestAsync(new JsonObject { ["type"] = "roster" });
        if (!J.B(reply["ok"])) return;
        Roster = Roster.FromJson(reply);
        Changed?.Invoke();
    }

    public Task<JsonObject> TrayAsync(string action) =>
        _link.RequestAsync(new JsonObject { ["type"] = "tray", ["action"] = action });

    public Task<JsonObject> HooksAsync(string action, string agent = "claude", string? token = null, bool statusline = true)
    {
        var req = new JsonObject { ["type"] = "hooks", ["action"] = action, ["agent"] = agent, ["statusline"] = statusline };
        if (token != null) req["token"] = token;
        return _link.RequestAsync(req);
    }

    // ── demo ───────────────────────────────────────────────────────────

    public void SetDemo(IReadOnlyList<JsonObject> sessions, IReadOnlyList<JsonObject> pending)
    {
        DemoActive = true;
        ApplySessions(sessions, announce: true);
        Pending = pending.Select(PendingRequest.FromJson).OfType<PendingRequest>().ToList();
        Changed?.Invoke();
    }

    public void EndDemo()
    {
        DemoActive = false;
        Sessions = Array.Empty<AgentSession>();
        Pending = Array.Empty<PendingRequest>();
        _lastStates = new();
        Changed?.Invoke();
        _ = RestoreAfterDemoAsync();
    }

    private async Task RestoreAfterDemoAsync()
    {
        var s = _link.RequestAsync(new JsonObject { ["type"] = "sessions" });
        var p = _link.RequestAsync(new JsonObject { ["type"] = "pending" });
        var sr = await s;
        if (J.B(sr["ok"]) || sr["sessions"] != null) ApplySessions(J.Arr(sr["sessions"]), announce: false);
        var pr = await p;
        if (pr["pending"] != null) Pending = ParsePending(pr["pending"]);
        Changed?.Invoke();
    }
}
