using Jarvis.Core.Link;

namespace Jarvis.Tests.Fakes;

/// An in-memory IJcLink: records every request, answers through `Reply`, and lets a test
/// push messages or flip the connection.
public sealed class FakeLink : IJcLink
{
    private readonly object _lock = new();
    private readonly List<JsonObject> _sent = new();

    public bool Connected { get; set; } = true;
    public event Action<JsonObject>? Message;
    public event Action<bool>? ConnectionChanged;
    public Func<JsonObject, JsonObject> Reply { get; set; } = _ => new JsonObject { ["ok"] = true };
    /// When set, replies wait for it (to observe optimistic updates).
    public TaskCompletionSource? Hold { get; set; }
    public bool Started { get; private set; }

    public IReadOnlyList<JsonObject> Sent { get { lock (_lock) return _sent.ToList(); } }

    public IReadOnlyList<JsonObject> SentOfType(string type) => Sent.Where(s => J.S(s["type"]) == type).ToList();

    public void Start() => Started = true;

    public async Task<JsonObject> RequestAsync(JsonObject body, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        lock (_lock) _sent.Add((JsonObject)body.DeepClone());
        if (Hold != null) await Hold.Task;
        return Reply(body);
    }

    public void Push(JsonObject msg) => Message?.Invoke(msg);

    public void SetConnected(bool up)
    {
        Connected = up;
        ConnectionChanged?.Invoke(up);
    }
}
