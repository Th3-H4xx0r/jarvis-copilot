using System.Net;
using System.Net.Sockets;
using System.Text;
using Jarvis.Core.Holo;
using Jarvis.Core.Link;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Holo;

public class HoloLanServerTests
{
    /// One raw HTTP exchange (so a test can leave out Content-Length): the status and the body.
    internal static async Task<(int Status, string Body)> Raw(int port, string head, byte[]? body = null)
    {
        using var c = new TcpClient();
        await c.ConnectAsync(IPAddress.Loopback, port);
        var s = c.GetStream();
        await s.WriteAsync(Encoding.ASCII.GetBytes(head));
        if (body != null) await s.WriteAsync(body);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var ms = new MemoryStream();
        var buf = new byte[8192];
        int n;
        while ((n = await s.ReadAsync(buf, cts.Token)) > 0) ms.Write(buf, 0, n);
        var text = Encoding.UTF8.GetString(ms.ToArray());
        const string interim = "HTTP/1.1 100 Continue\r\n\r\n";
        if (text.StartsWith(interim, StringComparison.Ordinal)) text = text[interim.Length..];
        var status = int.Parse(text.Split(' ')[1]);
        var split = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        return (status, split < 0 ? "" : text[(split + 4)..]);
    }

    private static HoloLanServer Server(out int port)
    {
        var s = new HoloLanServer(tempRoot: Tmp.Dir());
        port = s.Start(IPAddress.Loopback);
        return s;
    }

    [Fact]
    public async Task Lan_WrongToken401_MissingLength411_TooLarge413()
    {
        using var s = Server(out var port);
        var token = s.NewToken(TimeSpan.FromMinutes(15));
        var called = 0;
        s.OnDrop = (_, _, _) => { called++; return Task.FromResult(HoloOutcome.Copied); };
        var meta = HoloWire.Meta(new JsonObject { ["kind"] = "text" });

        var wrong = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nHost: x\r\nX-Holo-Token: nope\r\nX-Holo-Meta: {meta}\r\nContent-Length: 0\r\n\r\n");
        Assert.Equal(401, wrong.Status);

        var noLength = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nHost: x\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\n\r\n");
        Assert.Equal(411, noLength.Status);

        var big = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nHost: x\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\nContent-Length: {HoloLanServer.InlineCap + 1}\r\n\r\n");
        Assert.Equal(413, big.Status);
        Assert.Equal("too large", J.S(J.Parse(big.Body)["error"]));

        var get = await Raw(port, "GET /holo-drop HTTP/1.1\r\nHost: x\r\n\r\n");
        Assert.Equal(405, get.Status);
        var elsewhere = await Raw(port, "GET /other HTTP/1.1\r\nHost: x\r\n\r\n");
        Assert.Equal(404, elsewhere.Status);
        Assert.Equal(0, called);
    }

    [Fact]
    public async Task Lan_GoodPost_DecodesMetaAndLands()
    {
        using var s = Server(out var port);
        var token = s.NewToken(TimeSpan.FromMinutes(15));
        JsonObject? gotFields = null, gotInline = null;
        string? gotFile = "unset";
        s.OnDrop = (f, file, inline) => { gotFields = f; gotFile = file; gotInline = inline; return Task.FromResult(HoloOutcome.Copied); };
        var meta = HoloWire.Meta(new JsonObject { ["kind"] = "text", ["text"] = "hi" });
        var body = Encoding.UTF8.GetBytes("{\"text\":\"hi\"}");
        var r = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nHost: x\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\n\r\n", body);
        Assert.Equal(200, r.Status);
        Assert.Equal("{\"ok\":true,\"outcome\":\"copied\"}", J.SortedJson(J.Parse(r.Body)));
        Assert.Equal("text", J.S(gotFields!["kind"]));
        Assert.Equal("hi", J.S(gotFields!["text"]));
        Assert.Equal("hi", J.S(gotInline!["text"]));
        Assert.Null(gotFile);
    }

    [Fact]
    public async Task Lan_FilePost_StreamsToTempFile_ThenCleansUp()
    {
        var root = Tmp.Dir();
        using var s = new HoloLanServer(tempRoot: root);
        var port = s.Start(IPAddress.Loopback);
        var token = s.NewToken(TimeSpan.FromMinutes(15));
        string? content = null, path = null;
        s.OnDrop = (f, file, _) =>
        {
            path = file;
            content = File.ReadAllText(file!);
            return Task.FromResult(HoloOutcome.Saved);
        };
        var meta = HoloWire.Meta(new JsonObject { ["kind"] = "file", ["name"] = "a.txt" });
        var body = Encoding.UTF8.GetBytes("file bytes");
        var r = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nHost: x\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\nExpect: 100-continue\r\nContent-Length: {body.Length}\r\n\r\n", body);
        Assert.Equal(200, r.Status);
        Assert.Equal("file bytes", content);
        Assert.StartsWith(Path.Combine(root, "HoloDrop-lan-"), path);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task Lan_FailedLanding_500()
    {
        using var s = Server(out var port);
        var token = s.NewToken(TimeSpan.FromMinutes(15));
        s.OnDrop = (_, _, _) => Task.FromResult(HoloOutcome.Failed);
        var meta = HoloWire.Meta(new JsonObject { ["kind"] = "text" });
        var r = await Raw(port, $"POST /holo-drop HTTP/1.1\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\nContent-Length: 2\r\n\r\n", "{}"u8.ToArray());
        Assert.Equal(500, r.Status);
        Assert.Equal("{\"ok\":false,\"outcome\":\"failed\"}", J.SortedJson(J.Parse(r.Body)));
    }

    [Fact]
    public void Tokens_ExpireButOlderStayGood()
    {
        var time = new ManualTime();
        using var s = new HoloLanServer(time, Tmp.Dir());
        var a = s.NewToken(TimeSpan.FromMinutes(15));
        time.Advance(TimeSpan.FromMinutes(10));
        var b = s.NewToken(TimeSpan.FromMinutes(15));
        Assert.True(s.Accepts(a));
        Assert.True(s.Accepts(b));
        time.Advance(TimeSpan.FromMinutes(6));
        Assert.False(s.Accepts(a));
        Assert.True(s.Accepts(b));
        Assert.False(s.Accepts(null));
        Assert.Equal(48, b.Length);
    }

    [Fact]
    public void StopClearsPortAndTokens()
    {
        var s = Server(out var port);
        Assert.Equal(port, s.Port);
        var t = s.NewToken(TimeSpan.FromMinutes(1));
        s.Stop();
        Assert.Null(s.Port);
        Assert.False(s.Running);
        Assert.False(s.Accepts(t));
    }
}
