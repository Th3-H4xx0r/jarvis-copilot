using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Jarvis.Core.Link;

namespace Jarvis.Tests.Fakes;

/// A stand-in for jc-client's Windows link (C1 + C2): a loopback listener, an endpoint file
/// written atomically, the `{"auth":"<token>"}` first line, a `hello`, then newline JSON with
/// `{"type":"reply","id":n,...}` answers.
public sealed class FakeJcClient : IAsyncDisposable
{
    private readonly object _lock = new();
    private readonly string _dir;
    private readonly List<string> _firstLines = new();
    private readonly List<JsonObject> _requests = new();
    private readonly List<(TcpClient Client, NetworkStream Stream, SemaphoreSlim Write)> _clients = new();
    private TcpListener? _listener;
    private CancellationTokenSource _cts = new();

    public string EndpointPath => Path.Combine(_dir, "ui.sock");
    public string Token { get; private set; }
    public int Port { get; private set; }
    public JsonObject Hello { get; set; }
    /// How long after a good auth line the hello goes out.
    public TimeSpan HelloDelay { get; set; } = TimeSpan.Zero;
    public Func<JsonObject, JsonObject> OnRequest { get; set; } = _ => new JsonObject { ["ok"] = true };
    /// Takes precedence over OnRequest when set; returning null never answers.
    public Func<JsonObject, Task<JsonObject?>>? OnRequestAsync { get; set; }

    public IReadOnlyList<string> FirstLines { get { lock (_lock) return _firstLines.ToList(); } }
    public IReadOnlyList<JsonObject> Requests { get { lock (_lock) return _requests.ToList(); } }
    public int ClientCount { get { lock (_lock) return _clients.Count; } }

    private FakeJcClient(string dir, string token, JsonObject hello)
    {
        _dir = dir;
        Token = token;
        Hello = hello;
    }

    public static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    public static async Task<FakeJcClient> StartAsync(string dir, string? token = null, JsonObject? hello = null)
    {
        var f = new FakeJcClient(dir, token ?? NewToken(), hello ?? new JsonObject { ["api"] = "http://127.0.0.1:9", ["platform"] = "windows" });
        await f.ListenAsync();
        return f;
    }

    private Task ListenAsync()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        WriteEndpoint();
        var listener = _listener;
        var ct = _cts.Token;
        _ = Task.Run(() => AcceptLoop(listener, ct));
        return Task.CompletedTask;
    }

    private void WriteEndpoint()
    {
        var body = new JsonObject { ["v"] = 1, ["port"] = Port, ["token"] = Token, ["pid"] = Environment.ProcessId };
        var tmp = EndpointPath + ".tmp";
        File.WriteAllText(tmp, body.ToJsonString());
        File.Move(tmp, EndpointPath, overwrite: true);
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await listener.AcceptTcpClientAsync(ct); }
            catch { return; }
            _ = Task.Run(() => Serve(c, ct));
        }
    }

    private async Task Serve(TcpClient c, CancellationToken ct)
    {
        var stream = c.GetStream();
        var write = new SemaphoreSlim(1, 1);
        var buffer = new List<byte>();
        var chunk = new byte[65536];
        bool authed = false;
        try
        {
            using var authCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            authCts.CancelAfter(TimeSpan.FromSeconds(2));
            while (true)
            {
                int n;
                try { n = await stream.ReadAsync(chunk, authed ? ct : authCts.Token); }
                catch { break; }
                if (n <= 0) break;
                buffer.AddRange(chunk.AsSpan(0, n).ToArray());
                int nl;
                while ((nl = buffer.IndexOf((byte)'\n')) >= 0)
                {
                    var line = Encoding.UTF8.GetString(buffer.GetRange(0, nl).ToArray());
                    buffer.RemoveRange(0, nl + 1);
                    if (!authed)
                    {
                        lock (_lock) _firstLines.Add(line);
                        if (!AuthOk(line)) { c.Close(); return; }
                        authed = true;
                        lock (_lock) _clients.Add((c, stream, write));
                        if (HelloDelay > TimeSpan.Zero) await Task.Delay(HelloDelay, ct);
                        var hello = (JsonObject)Hello.DeepClone();
                        hello["type"] = "hello";
                        await Send(stream, write, hello);
                        continue;
                    }
                    JsonObject req;
                    try { req = (JsonObject)JsonNode.Parse(line)!; } catch { continue; }
                    lock (_lock) _requests.Add(req);
                    _ = Task.Run(() => Answer(stream, write, req));
                }
            }
        }
        finally
        {
            lock (_lock) _clients.RemoveAll(x => x.Client == c);
            try { c.Close(); } catch { }
        }
    }

    private bool AuthOk(string line)
    {
        try
        {
            var o = JsonNode.Parse(line) as JsonObject;
            return o != null && o.Count == 1 && o["auth"]?.GetValueKind() == JsonValueKind.String && (string)o["auth"]! == Token;
        }
        catch { return false; }
    }

    private async Task Answer(NetworkStream stream, SemaphoreSlim write, JsonObject req)
    {
        JsonObject? result = OnRequestAsync != null ? await OnRequestAsync(req) : OnRequest(req);
        if (result == null) return;
        var reply = new JsonObject { ["type"] = "reply", ["id"] = req["id"]?.DeepClone() };
        foreach (var (k, v) in result) reply[k] = v?.DeepClone();
        try { await Send(stream, write, reply); } catch { }
    }

    private static async Task Send(NetworkStream stream, SemaphoreSlim write, JsonObject msg)
    {
        var bytes = Encoding.UTF8.GetBytes(msg.ToJsonString() + "\n");
        await write.WaitAsync();
        try { await stream.WriteAsync(bytes); }
        finally { write.Release(); }
    }

    public async Task BroadcastAsync(JsonObject msg)
    {
        List<(TcpClient, NetworkStream S, SemaphoreSlim W)> clients;
        lock (_lock) clients = _clients.ToList();
        foreach (var c in clients)
        {
            try { await Send(c.S, c.W, (JsonObject)msg.DeepClone()); } catch { }
        }
    }

    public Task DropClientsAsync()
    {
        List<(TcpClient C, NetworkStream, SemaphoreSlim)> clients;
        lock (_lock) { clients = _clients.ToList(); _clients.Clear(); }
        foreach (var c in clients) { try { c.C.Close(); } catch { } }
        return Task.CompletedTask;
    }

    /// jc-client restarted: new port, new token, the file rewritten, old clients dropped.
    public async Task RestartAsync()
    {
        _cts.Cancel();
        _listener?.Stop();
        await DropClientsAsync();
        _cts = new CancellationTokenSource();
        Token = NewToken();
        await ListenAsync();
    }

    public async Task<JsonObject> WaitForRequestAsync(string type, TimeSpan timeout)
    {
        var end = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < end)
        {
            var hit = Requests.FirstOrDefault(r => J.S(r["type"]) == type);
            if (hit != null) return hit;
            await Task.Delay(10);
        }
        throw new TimeoutException($"no {type} request within {timeout}");
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        _listener?.Stop();
        await DropClientsAsync();
        try { File.Delete(EndpointPath); } catch { }
    }
}
