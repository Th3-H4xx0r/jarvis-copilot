using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Http;

public sealed class ApiException : Exception
{
    public int Status { get; }
    public string Error { get; }

    public ApiException(int status, string error) : base(status == 0 ? error : $"{status}: {error}")
    {
        Status = status;
        Error = error;
    }
}

public sealed record SseEvent(string Event, string Data);

/// The server, through jc-client's loopback proxy origin (`hello.api`). The app never holds
/// credentials: the proxy adds them.
public sealed class ApiClient
{
    public const string UserAgent = "Jarvis-PC/1";
    public const string NotConnected = "Jarvis isn't connected to the server yet";

    private readonly Func<string?> _origin;
    private readonly HttpClient _http;

    public ApiClient(Func<string?> origin, HttpMessageHandler? handler = null)
    {
        _origin = origin;
        _http = new HttpClient(handler ?? new SocketsHttpHandler(), disposeHandler: handler == null)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
    }

    private Uri Url(string path)
    {
        var o = _origin();
        if (string.IsNullOrEmpty(o)) throw new ApiException(0, NotConnected);
        return new Uri(o.TrimEnd('/') + path);
    }

    public Task<JsonObject> GetAsync(string path, TimeSpan timeout) =>
        SendJsonAsync(new HttpRequestMessage(HttpMethod.Get, Url(path)), timeout);

    public Task<JsonObject> PostAsync(string path, JsonNode body, TimeSpan timeout) =>
        SendJsonAsync(new HttpRequestMessage(HttpMethod.Post, Url(path)) { Content = JsonContent(body) }, timeout);

    /// POST with extra headers (Holo Drop's LAN receiver needs X-Holo-*), to an absolute URL.
    public async Task<JsonObject> PostAbsoluteAsync(Uri url, HttpContent content, IReadOnlyDictionary<string, string> headers, TimeSpan timeout)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
        foreach (var (k, v) in headers) req.Headers.TryAddWithoutValidation(k, v);
        return await SendJsonAsync(req, timeout).ConfigureAwait(false);
    }

    public Task<JsonObject> UploadAsync(string path, Stream body, string contentType, TimeSpan timeout)
    {
        var content = new StreamContent(body);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return SendJsonAsync(new HttpRequestMessage(HttpMethod.Post, Url(path)) { Content = content }, timeout);
    }

    public async Task<Stream> DownloadAsync(string path, CancellationToken ct)
    {
        var url = path.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || path.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            ? new Uri(path) : Url(path);
        var resp = await _http.SendAsync(new HttpRequestMessage(HttpMethod.Get, url), HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        await EnsureOk(resp, ct).ConfigureAwait(false);
        return await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
    }

    public async IAsyncEnumerable<JsonObject> NdjsonAsync(string path, JsonNode body, [EnumeratorCancellation] CancellationToken ct)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, Url(path)) { Content = JsonContent(body) };
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        await EnsureOk(resp, ct).ConfigureAwait(false);
        using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false), Encoding.UTF8);
        while (await reader.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
        {
            if (line.Length == 0) continue;
            JsonObject? o = null;
            try { o = JsonNode.Parse(line) as JsonObject; } catch (JsonException) { }
            if (o != null) yield return o;
        }
    }

    public IAsyncEnumerable<SseEvent> SseAsync(string path, CancellationToken ct) =>
        ReadSse(new HttpRequestMessage(HttpMethod.Get, Url(path)), ct);

    /// POST a JSON body and read the answer as server-sent events (`/api/chat/start?stream=1`).
    public IAsyncEnumerable<SseEvent> PostSseAsync(string path, JsonNode body, CancellationToken ct) =>
        ReadSse(new HttpRequestMessage(HttpMethod.Post, Url(path)) { Content = JsonContent(body) }, ct);

    private async IAsyncEnumerable<SseEvent> ReadSse(HttpRequestMessage req, [EnumeratorCancellation] CancellationToken ct)
    {
        req.Headers.Accept.ParseAdd("text/event-stream");
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        await EnsureOk(resp, ct).ConfigureAwait(false);
        using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false), Encoding.UTF8);
        var ev = "message";
        var data = new List<string>();
        while (await reader.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
        {
            if (line.Length == 0)
            {
                if (data.Count > 0) yield return new SseEvent(ev, string.Join("\n", data));
                ev = "message";
                data.Clear();
                continue;
            }
            if (line.StartsWith(':')) continue;
            var colon = line.IndexOf(':');
            var field = colon < 0 ? line : line[..colon];
            var value = colon < 0 ? "" : line[(colon + 1)..].TrimStart(' ');
            if (field == "event") ev = value;
            else if (field == "data") data.Add(value);
        }
        if (data.Count > 0) yield return new SseEvent(ev, string.Join("\n", data));
    }

    private static StringContent JsonContent(JsonNode body) =>
        new(body.ToJsonString(), Encoding.UTF8, "application/json");

    private async Task<JsonObject> SendJsonAsync(HttpRequestMessage req, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req, cts.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw new ApiException(0, "timed out"); }
        catch (HttpRequestException e) { throw new ApiException(0, e.Message); }
        using (resp)
        {
            await EnsureOk(resp, cts.Token).ConfigureAwait(false);
            var text = await resp.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            try
            {
                return JsonNode.Parse(text) switch
                {
                    JsonObject o => o,
                    JsonArray a => new JsonObject { ["items"] = a },
                    _ => new JsonObject(),
                };
            }
            catch (JsonException) { throw new ApiException((int)resp.StatusCode, "the server's answer wasn't JSON"); }
        }
    }

    private static async Task EnsureOk(HttpResponseMessage resp, CancellationToken ct)
    {
        if (resp.IsSuccessStatusCode) return;
        var text = "";
        try { text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false); } catch (Exception) { }
        string error = resp.ReasonPhrase ?? "request failed";
        try
        {
            if (JsonNode.Parse(text) is JsonObject o && J.StrOrNull(o["error"]) is { Length: > 0 } e) error = e;
        }
        catch (JsonException) { }
        throw new ApiException((int)resp.StatusCode, error);
    }
}
