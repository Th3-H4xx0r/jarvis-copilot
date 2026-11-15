using System.IO;
using System.Net.WebSockets;
using System.Text;
using Jarvis.Core.Voice;

namespace Jarvis.Voice;

/// The realtime voice socket over ClientWebSocket: text frames are JSON, binary frames are reply
/// audio. Sends are serialised; one receive loop raises Text/Binary/Closed.
public sealed class VoiceSocket : IVoiceSocket
{
    private readonly ClientWebSocket _ws = new();
    private readonly SemaphoreSlim _send = new(1, 1);
    private readonly CancellationTokenSource _cts = new();
    private bool _closing;

    public event Action<string>? Text;
    public event Action<byte[]>? Binary;
    public event Action<string?>? Closed;

    public async Task ConnectAsync(Uri url, CancellationToken ct)
    {
        _ws.Options.SetRequestHeader("User-Agent", "Jarvis-PC/1");
        _ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        await _ws.ConnectAsync(url, timeout.Token).ConfigureAwait(false);
        _ = Task.Run(ReceiveLoop);
    }

    public Task SendTextAsync(string text) => SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text);

    public Task SendBinaryAsync(ReadOnlyMemory<byte> data) => SendAsync(data, WebSocketMessageType.Binary);

    private async Task SendAsync(ReadOnlyMemory<byte> data, WebSocketMessageType type)
    {
        if (_ws.State != WebSocketState.Open) return;
        await _send.WaitAsync().ConfigureAwait(false);
        try { await _ws.SendAsync(data, type, true, _cts.Token).ConfigureAwait(false); }
        catch (Exception e) when (e is WebSocketException or OperationCanceledException or ObjectDisposedException) { }
        finally { _send.Release(); }
    }

    private async Task ReceiveLoop()
    {
        var buf = new byte[64 * 1024];
        var msg = new MemoryStream();
        string? reason = null;
        try
        {
            while (_ws.State == WebSocketState.Open)
            {
                var r = await _ws.ReceiveAsync(buf, _cts.Token).ConfigureAwait(false);
                if (r.MessageType == WebSocketMessageType.Close) { reason = _closing ? null : (r.CloseStatusDescription ?? "closed"); break; }
                msg.Write(buf, 0, r.Count);
                if (!r.EndOfMessage) continue;
                var bytes = msg.ToArray();
                msg.SetLength(0);
                if (r.MessageType == WebSocketMessageType.Text) Text?.Invoke(Encoding.UTF8.GetString(bytes));
                else Binary?.Invoke(bytes);
            }
        }
        catch (Exception e) when (e is WebSocketException or OperationCanceledException or ObjectDisposedException)
        {
            reason = _closing ? null : e.Message;
        }
        Closed?.Invoke(reason);
    }

    public async Task CloseAsync()
    {
        _closing = true;
        try
        {
            if (_ws.State == WebSocketState.Open)
                await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException) { }
        _cts.Cancel();
        _ws.Dispose();
    }
}
