using System.Text.Json.Nodes;

namespace Jarvis.Core.Link;

/// The app's line to jc-client (C1 + C2). Events fire on the link's own thread; callers marshal.
public interface IJcLink
{
    bool Connected { get; }
    event Action<JsonObject>? Message;
    event Action<bool>? ConnectionChanged;
    void Start();
    /// Never throws on a link failure: answers `{"ok":false,"error":...}` instead.
    Task<JsonObject> RequestAsync(JsonObject body, TimeSpan? timeout = null, CancellationToken ct = default);
}
