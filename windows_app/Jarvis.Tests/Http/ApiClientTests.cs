using System.Net;
using System.Text;
using Jarvis.Core.Admin;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Http;

public class ApiClientTests
{
    [Fact]
    public async Task Get_JoinsOriginAndPath_SendsUserAgent()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"ok\":true,\"n\":3}"));
        var api = new ApiClient(() => "http://127.0.0.1:8787", h);
        var r = await api.GetAsync("/api/power", TimeSpan.FromSeconds(5));
        Assert.Equal(3, J.I(r["n"]));
        Assert.Equal("http://127.0.0.1:8787/api/power", h.Requests[0].Uri);
        Assert.Equal("Jarvis-PC/1", h.Requests[0].UserAgent);
    }

    [Fact]
    public async Task Post_SendsJsonBody()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"ok\":true}"));
        var api = new ApiClient(() => "http://o", h);
        await api.PostAsync("/api/x", new JsonObject { ["a"] = 1 }, TimeSpan.FromSeconds(5));
        Assert.Equal("POST", h.Requests[0].Method);
        Assert.Equal("{\"a\":1}", h.Requests[0].Body);
        Assert.Equal("application/json", h.Requests[0].ContentType);
    }

    [Fact]
    public async Task Error_ThrowsApiExceptionWithServerError()
    {
        var api = new ApiClient(() => "http://o", new FakeHttp(_ => FakeHttp.Json("{\"error\":\"nope\"}", HttpStatusCode.Forbidden)));
        var e = await Assert.ThrowsAsync<ApiException>(() => api.GetAsync("/api/x", TimeSpan.FromSeconds(5)));
        Assert.Equal(403, e.Status);
        Assert.Equal("nope", e.Error);
    }

    [Fact]
    public async Task NoOrigin_Throws()
    {
        var api = new ApiClient(() => null, new FakeHttp(_ => FakeHttp.Json("{}")));
        var e = await Assert.ThrowsAsync<ApiException>(() => api.GetAsync("/api/x", TimeSpan.FromSeconds(5)));
        Assert.Equal(0, e.Status);
    }

    [Fact]
    public async Task Ndjson_YieldsObjects()
    {
        var api = new ApiClient(() => "http://o", new FakeHttp(_ => FakeHttp.Text("{\"a\":1}\n\nnope\n{\"a\":2}\n")));
        var got = new List<int>();
        await foreach (var o in api.NdjsonAsync("/api/chat", new JsonObject(), CancellationToken.None)) got.Add(J.I(o["a"]));
        Assert.Equal(new[] { 1, 2 }, got);
    }

    [Fact]
    public async Task Sse_YieldsEvents()
    {
        var api = new ApiClient(() => "http://o", new FakeHttp(_ => FakeHttp.Text("event: delta\ndata: {\"t\":\"hi\"}\n\ndata: one\ndata: two\n\n")));
        var got = new List<SseEvent>();
        await foreach (var e in api.SseAsync("/api/stream", CancellationToken.None)) got.Add(e);
        Assert.Equal(new[] { new SseEvent("delta", "{\"t\":\"hi\"}"), new SseEvent("message", "one\ntwo") }, got);
    }

    [Fact]
    public async Task Upload_SendsStreamWithType()
    {
        var h = new FakeHttp(_ => FakeHttp.Json("{\"ok\":true}"));
        var api = new ApiClient(() => "http://o", h);
        await api.UploadAsync("/api/up", new MemoryStream(Encoding.UTF8.GetBytes("raw")), "image/png", TimeSpan.FromSeconds(5));
        Assert.Equal("raw", h.Requests[0].Body);
        Assert.Equal("image/png", h.Requests[0].ContentType);
    }
}

public class AdminRunnerTests
{
    [Fact]
    public async Task Run_SendsAdminRun_ReportsApproved()
    {
        var link = new FakeLink { Reply = _ => J.Parse("{\"ok\":true,\"status\":\"approved\"}") };
        var r = new AdminRunner(link);
        string? asking = null;
        AdminResult? done = null;
        r.Asking += w => asking = w;
        r.Done += d => done = d;
        var res = await r.RunAsync("netsh advfirewall show", "Let Holo Drop in");
        Assert.Equal("{\"command\":\"netsh advfirewall show\",\"type\":\"admin_run\",\"why\":\"Let Holo Drop in\"}", J.SortedJson(link.Sent.Single()));
        Assert.Equal(new AdminResult(true, "approved", null), res);
        Assert.Equal("Let Holo Drop in", asking);
        Assert.Equal(res, done);
    }

    [Theory]
    [InlineData("{\"ok\":false,\"status\":\"denied\"}", "denied")]
    [InlineData("{\"ok\":false,\"status\":\"timeout\"}", "timeout")]
    [InlineData("{\"ok\":false,\"error\":\"timed out\"}", "timeout")]
    [InlineData("{\"ok\":false,\"error\":\"Jarvis isn't running on this PC\"}", "error")]
    public async Task Run_MapsStatuses(string reply, string status)
    {
        var r = new AdminRunner(new FakeLink { Reply = _ => J.Parse(reply) });
        Assert.Equal(status, (await r.RunAsync("x", "y")).Status);
    }
}
