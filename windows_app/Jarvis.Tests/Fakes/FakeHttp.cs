using System.Net;
using System.Text;

namespace Jarvis.Tests.Fakes;

/// An HttpMessageHandler that records requests and answers through `Respond`.
public sealed class FakeHttp : HttpMessageHandler
{
    public sealed record Seen(string Method, string Uri, string Path, string? Body, string? ContentType, string? UserAgent,
        IReadOnlyDictionary<string, string> Headers);

    private readonly object _lock = new();
    private readonly List<Seen> _requests = new();
    public Func<Seen, HttpResponseMessage> Respond { get; set; }

    public FakeHttp(Func<Seen, HttpResponseMessage> respond) => Respond = respond;

    public IReadOnlyList<Seen> Requests { get { lock (_lock) return _requests.ToList(); } }

    public IReadOnlyList<Seen> To(string pathPrefix) => Requests.Where(r => r.Path.StartsWith(pathPrefix, StringComparison.Ordinal)).ToList();

    public static HttpResponseMessage Json(string json, HttpStatusCode code = HttpStatusCode.OK) =>
        new(code) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage Text(string text, HttpStatusCode code = HttpStatusCode.OK) =>
        new(code) { Content = new StringContent(text, Encoding.UTF8, "text/plain") };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        string? body = request.Content != null ? await request.Content.ReadAsStringAsync(ct) : null;
        var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value));
        var seen = new Seen(request.Method.Method, request.RequestUri!.ToString(), request.RequestUri!.PathAndQuery, body,
            request.Content?.Headers.ContentType?.MediaType, request.Headers.UserAgent.ToString(), headers);
        lock (_lock) _requests.Add(seen);
        return Respond(seen);
    }
}
