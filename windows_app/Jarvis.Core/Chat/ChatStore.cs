using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Platform;

namespace Jarvis.Core.Chat;

/// The island's chat (port of the Mac's ChatStore): Jarvis through the server (one "PC island"
/// session, `/api/chat/start?stream=1` as SSE, Stop through `/api/chat/cancel`, approvals and
/// questions answered inline), or a local Ollama / LM Studio model (OpenAI-style streaming).
public sealed class ChatStore
{
    public enum Backend { Jarvis, Ollama, LmStudio }

    private readonly ApiClient _api;
    private readonly HttpClient _local;
    private readonly List<ChatTurn> _turns = new();
    private readonly List<JsonObject> _localHistory = new();
    private CancellationTokenSource? _cts;
    private ChatStreamState? _stream;
    private string? _session;

    public ChatStore(ApiClient api, HttpMessageHandler? localHandler = null)
    {
        _api = api;
        _local = new HttpClient(localHandler ?? new SocketsHttpHandler(), disposeHandler: localHandler == null) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public ChatRunChoice Choice { get; set; } = new ChatRunChoice.ChatDefault();
    public Backend Source { get; set; } = Backend.Jarvis;
    public string LocalModelName { get; set; } = "";
    public FrontWindow? Attached { get; set; }
    public List<ChatContext.Attachment> Files { get; } = new();
    public bool Busy => _cts != null;
    public ChatApproval? Approval => _stream?.Approval;
    public ChatClarify? Clarify => _stream?.Clarify;
    public string? SessionId => _session;

    public IReadOnlyList<ChatTurn> Turns
    {
        get
        {
            var list = _turns.ToList();
            if (_stream != null && !_stream.Ended) list.Add(_stream.ToTurn());
            return list;
        }
    }

    public event Action? Changed;

    public async Task SendAsync(string text)
    {
        text = text.Trim();
        if (text.Length == 0 || Busy) return;
        var prompt = ChatContext.Prompt(text, Files, ChatContext.FromFront(Attached));
        _turns.Add(new ChatTurn(true, text));
        Attached = null;
        _cts = new CancellationTokenSource();
        Changed?.Invoke();
        try
        {
            if (Source == Backend.Jarvis) await SendJarvisAsync(prompt, _cts.Token).ConfigureAwait(false);
            else await SendLocalAsync(prompt, _cts.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is ApiException or HttpRequestException or IOException)
        {
            _turns.Add(new ChatTurn(false, "", Error: e is ApiException a ? a.Error : e.Message));
        }
        catch (OperationCanceledException)
        {
            if (_stream is { Ended: false } s) _turns.Add(s.ToTurn() with { Streaming = false, Stopped = true });
        }
        finally
        {
            _stream = null;
            Files.Clear();
            _cts?.Dispose();
            _cts = null;
            Changed?.Invoke();
        }
    }

    private async Task SendJarvisAsync(string prompt, CancellationToken ct)
    {
        _session ??= await NewSessionAsync().ConfigureAwait(false);
        var uploaded = new List<JsonObject>();
        foreach (var f in Files.Where(f => f.InlineText == null && ChatContext.CanUpload(f.Size)))
        {
            await using var stream = File.OpenRead(f.Path);
            uploaded.Add(await UploadAsync(f, stream).ConfigureAwait(false));
        }
        _stream = new ChatStreamState();
        await foreach (var e in _api.PostSseAsync("/api/chat/start?stream=1", ChatRequest.StartBody(_session, prompt, uploaded, Choice), ct).ConfigureAwait(false))
        {
            if (_stream.Apply(ChatSse.FromSse(e))) Changed?.Invoke();
            if (_stream.Ended) break;
        }
        _turns.Add(_stream.ToTurn() with { Streaming = false });
    }

    private async Task<JsonObject> UploadAsync(ChatContext.Attachment f, Stream body)
    {
        var form = new MultipartFormDataContent();
        var file = new StreamContent(body);
        file.Headers.ContentType = new MediaTypeHeaderValue(f.IsImage ? "image/" + Path.GetExtension(f.Name).TrimStart('.').ToLowerInvariant() : "application/octet-stream");
        form.Add(file, "file", f.Name);
        form.Add(new StringContent(_session ?? ""), "session_id");
        return await _api.PostAbsoluteAsync(new Uri(ApiOrigin() + "/api/upload"), form, new Dictionary<string, string>(), TimeSpan.FromSeconds(120)).ConfigureAwait(false);
    }

    /// `POST /api/session/new` once; the id comes back as session_id, session.session_id, session.id or id.
    private async Task<string> NewSessionAsync()
    {
        var o = await _api.PostAsync("/api/session/new", new JsonObject { ["title"] = "PC island" }, TimeSpan.FromSeconds(60)).ConfigureAwait(false);
        var inner = J.Obj(o["session"]);
        var id = J.StrOrNull(o["session_id"]) ?? J.StrOrNull(inner["session_id"]) ?? J.StrOrNull(inner["id"]) ?? J.StrOrNull(o["id"]);
        return id is { Length: > 0 } ? id : throw new ApiException(0, "Couldn't start a chat with Jarvis.");
    }

    /// The origin the ApiClient uses (for the absolute multipart POST).
    public Func<string?> Origin { get; set; } = () => null;

    private string ApiOrigin() => (Origin() ?? throw new ApiException(0, ApiClient.NotConnected)).TrimEnd('/');

    private async Task SendLocalAsync(string prompt, CancellationToken ct)
    {
        var baseUrl = Source == Backend.Ollama ? LocalModel.Ollama : LocalModel.LmStudio;
        _localHistory.Add(new JsonObject { ["role"] = "user", ["content"] = prompt });
        var body = new JsonObject
        {
            ["model"] = LocalModelName,
            ["stream"] = true,
            ["messages"] = new JsonArray(_localHistory.Select(m => (JsonNode?)m.DeepClone()).ToArray()),
        };
        var req = new HttpRequestMessage(HttpMethod.Post, LocalModel.ChatUrl(baseUrl)) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        using var resp = await _local.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode) throw new ApiException((int)resp.StatusCode, $"{Source} answered {(int)resp.StatusCode}");
        using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
        _stream = new ChatStreamState();
        var raw = new StringBuilder();
        while (await reader.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
        {
            if (LocalModel.IsDone(line)) break;
            if (LocalModel.Delta(line) is not { } d) continue;
            raw.Append(d);
            _stream.Apply(new ChatEvent("token", new Dictionary<string, string> { ["text"] = d }, new JsonObject()));
            Changed?.Invoke();
        }
        var text = LocalModel.Visible(raw.ToString());
        _localHistory.Add(new JsonObject { ["role"] = "assistant", ["content"] = text });
        _turns.Add(new ChatTurn(false, text));
    }

    public async Task StopAsync()
    {
        if (_stream?.StreamId is { } id)
        {
            try { await _api.PostAsync("/api/chat/cancel?stream_id=" + Uri.EscapeDataString(id), new JsonObject(), TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
            catch (ApiException) { }
        }
        _cts?.Cancel();
    }

    public async Task AnswerApprovalAsync(ChatApproval.Choice choice)
    {
        if (_session == null || Approval is not { } a) return;
        await _api.PostAsync("/api/approval/respond", ChatApproval.RespondBody(_session, choice, a.Id), TimeSpan.FromSeconds(15)).ConfigureAwait(false);
    }

    public async Task AnswerClarifyAsync(string answer)
    {
        if (_session == null || Clarify == null) return;
        await _api.PostAsync("/api/clarify/respond", ChatClarify.RespondBody(_session, answer), TimeSpan.FromSeconds(15)).ConfigureAwait(false);
    }

    public void Clear()
    {
        _turns.Clear();
        _localHistory.Clear();
        _session = null;
        Changed?.Invoke();
    }
}
