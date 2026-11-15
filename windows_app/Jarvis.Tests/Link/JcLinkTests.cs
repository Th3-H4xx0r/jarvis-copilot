using System.Net;
using System.Net.Sockets;
using System.Text;
using Jarvis.Core.Link;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Link;

public class JcLinkTests
{
    private static async Task Until(Func<bool> cond, int ms = 3000)
    {
        var end = DateTime.UtcNow.AddMilliseconds(ms);
        while (!cond())
        {
            if (DateTime.UtcNow > end) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task Link_SendsAuthLineFirst()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        await using var link = new JcLink(fake.EndpointPath);
        link.Start();
        await Until(() => link.Connected);
        Assert.Equal("{\"auth\":\"" + fake.Token + "\"}", fake.FirstLines[0]);
    }

    [Fact]
    public async Task Link_ConnectedOnlyAfterHello()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        fake.HelloDelay = TimeSpan.FromMilliseconds(300);
        await using var link = new JcLink(fake.EndpointPath);
        var ups = 0;
        link.ConnectionChanged += up => { if (up) Interlocked.Increment(ref ups); };
        link.Start();
        await Task.Delay(100);
        Assert.False(link.Connected);
        await Task.Delay(400);
        Assert.True(link.Connected);
        Assert.Equal(1, ups);
    }

    [Fact]
    public async Task Link_HelloIsRaisedAsMessage()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        await using var link = new JcLink(fake.EndpointPath);
        JsonObject? hello = null;
        link.Message += m => { if (J.S(m["type"]) == "hello") hello = m; };
        link.Start();
        await Until(() => hello != null);
        Assert.Equal("windows", J.S(hello!["platform"]));
    }

    [Fact]
    public async Task Link_RequestsMatchRepliesById()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        var second = new TaskCompletionSource();
        fake.OnRequestAsync = async req =>
        {
            if (J.I(req["id"]) == 1) { await second.Task; return new JsonObject { ["ok"] = true, ["v"] = "one" }; }
            second.TrySetResult();
            return new JsonObject { ["ok"] = true, ["v"] = "two" };
        };
        await using var link = new JcLink(fake.EndpointPath);
        link.Start();
        await Until(() => link.Connected);
        var t1 = link.RequestAsync(new JsonObject { ["type"] = "a" });
        await fake.WaitForRequestAsync("a", TimeSpan.FromSeconds(2));
        var t2 = link.RequestAsync(new JsonObject { ["type"] = "b" });
        var r2 = await t2;
        var r1 = await t1;
        Assert.Equal(new[] { 1, 2 }, fake.Requests.Select(r => J.I(r["id"])).OrderBy(x => x));
        Assert.Equal("one", J.S(r1["v"]));
        Assert.Equal("two", J.S(r2["v"]));
    }

    [Fact]
    public async Task Link_RequestWhileDown_ReturnsDownErrorFast()
    {
        var r = await new JcLink(@"C:\nope\ui.sock").RequestAsync(new() { ["type"] = "sessions" });
        Assert.False(r["ok"]!.GetValue<bool>());
        Assert.Equal(JcLink.DownError, r["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task Link_DropMidRequest_FailsPendingWithLinkDropped()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        fake.OnRequestAsync = _ => Task.FromResult<JsonObject?>(null);
        await using var link = new JcLink(fake.EndpointPath);
        link.Start();
        await Until(() => link.Connected);
        var t = link.RequestAsync(new JsonObject { ["type"] = "slow" });
        await fake.WaitForRequestAsync("slow", TimeSpan.FromSeconds(2));
        await fake.DropClientsAsync();
        var r = await t;
        Assert.False(J.B(r["ok"]));
        Assert.Equal("the link dropped", J.S(r["error"]));
    }

    [Fact]
    public async Task Link_Timeout_ReturnsTimedOut()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        fake.OnRequestAsync = _ => Task.FromResult<JsonObject?>(null);
        await using var link = new JcLink(fake.EndpointPath);
        link.Start();
        await Until(() => link.Connected);
        var r = await link.RequestAsync(new JsonObject { ["type"] = "slow" }, TimeSpan.FromMilliseconds(200));
        Assert.False(J.B(r["ok"]));
        Assert.Equal("timed out", J.S(r["error"]));
    }

    [Fact]
    public async Task Link_ReconnectsAfterRestartOnNewPort()
    {
        await using var fake = await FakeJcClient.StartAsync(Tmp.Dir());
        await using var link = new JcLink(fake.EndpointPath);
        var ups = 0;
        link.ConnectionChanged += up => { if (up) Interlocked.Increment(ref ups); };
        link.Start();
        await Until(() => ups == 1);
        var oldPort = fake.Port;
        await fake.RestartAsync();
        Assert.NotEqual(oldPort, fake.Port);
        await Until(() => ups == 2, 3000);
        Assert.Equal("{\"auth\":\"" + fake.Token + "\"}", fake.FirstLines.Last());
    }

    [Fact]
    public async Task Link_PortOwnedByStranger_SendsOnlyAuthThenRetries()
    {
        var stranger = new TcpListener(IPAddress.Loopback, 0);
        stranger.Start();
        var port = ((IPEndPoint)stranger.LocalEndpoint).Port;
        var token = new string('b', 64);
        var path = Tmp.File("{\"v\":1,\"port\":" + port + ",\"token\":\"" + token + "\",\"pid\":1}");
        var received = new List<string>();
        var closedByClient = new TaskCompletionSource();
        var accepts = 0;
        _ = Task.Run(async () =>
        {
            var first = true;
            while (true)
            {
                TcpClient c;
                try { c = await stranger.AcceptTcpClientAsync(); } catch { return; }
                Interlocked.Increment(ref accepts);
                if (!first) continue;
                first = false;
                var s = c.GetStream();
                var buf = new byte[4096];
                var all = new StringBuilder();
                while (true)
                {
                    int n;
                    try { n = await s.ReadAsync(buf); } catch { n = 0; }
                    if (n <= 0) break;
                    all.Append(Encoding.UTF8.GetString(buf, 0, n));
                }
                lock (received) received.AddRange(all.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries));
                closedByClient.TrySetResult();
            }
        });
        await using var link = new JcLink(path);
        link.Start();
        await Task.Delay(2500);
        Assert.True(closedByClient.Task.IsCompleted, "the client should close after no hello in 2 s");
        lock (received) Assert.Equal(new[] { "{\"auth\":\"" + token + "\"}" }, received);
        Assert.False(link.Connected);
        await Until(() => Volatile.Read(ref accepts) >= 2, 2000);
        stranger.Stop();
    }

    [Fact]
    public void Backoff_StepsThenCaps()
    {
        var b = new Backoff();
        Assert.Equal(new[] { 250, 500, 1000, 2000, 2000 }, Enumerable.Range(0, 5).Select(_ => (int)b.Next().TotalMilliseconds));
        b.Reset();
        Assert.Equal(250, (int)b.Next().TotalMilliseconds);
    }

    [Fact]
    public void SortedJson_SortsKeysAtEveryLevel() =>
        Assert.Equal("{\"a\":[{\"x\":1,\"y\":2}],\"b\":{\"c\":true,\"d\":\"e\"}}",
            J.SortedJson(J.Parse("{\"b\":{\"d\":\"e\",\"c\":true},\"a\":[{\"y\":2,\"x\":1}]}")));

    [Fact]
    public void J_Helpers()
    {
        var o = J.Parse("{\"s\":\"x\",\"n\":3.7,\"ns\":\"2.5\",\"b\":true,\"o\":{\"k\":1},\"a\":[{\"k\":1},2,{\"k\":3}]}");
        Assert.Equal("x", J.S(o["s"]));
        Assert.Equal("3.7", J.S(o["n"]));
        Assert.Equal("fb", J.S(o["missing"], "fb"));
        Assert.Equal(2.5, J.D(o["ns"]));
        Assert.Null(J.D(o["s"]));
        Assert.Equal(3, J.I(o["n"]));
        Assert.True(J.B(o["b"]));
        Assert.False(J.B(o["s"]));
        Assert.Equal(1, J.I(J.Obj(o["o"])["k"]));
        Assert.Empty(J.Obj(o["s"]));
        Assert.Equal(2, J.Arr(o["a"]).Count);
    }
}
