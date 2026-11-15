namespace Jarvis.Core.Voice;

/// The rest of a reply the user cut off. The server generates faster than it speaks, so when an
/// interrupt reaches it the rest of the reply is often already on the wire. Everything is dropped
/// until that turn's own `end_turn` (which the server always sends before starting the next turn), or
/// for `Expiry` at most if it never comes. Port of VoiceStoreTransport.swift `handle(_:)` while
/// `discardingInterruptedTurn`, plus VoiceStore's `interruptedTurnExpiryMs`.
///
/// Call `Interrupted` only when the machine started discarding (`DiscardingInterruptedTurn`). The
/// `end_turn` that ends the dropping is not dropped: hand it to the machine as
/// `TurnEnded("interrupt", true)`. On expiry, raise `InterruptedTurnExpired`.
public sealed class PostInterruptFilter
{
    public static readonly TimeSpan Expiry = TimeSpan.FromSeconds(10);

    private DateTimeOffset? _since;

    public bool Active => _since != null;
    /// Reply frames dropped since the last interrupt (ready/latency/other aren't counted).
    public int Dropped { get; private set; }

    public void Interrupted(DateTimeOffset at)
    {
        _since = at;
        Dropped = 0;
    }

    public void Reset() => _since = null;

    /// True when `f` belongs to the cut-off reply and must not reach the reply, karaoke or speaker.
    public bool Drop(VoiceServerFrame f, DateTimeOffset now)
    {
        if (_since is not { } since) return false;
        if (now - since >= Expiry)
        {
            _since = null;
            return false;
        }
        if (f is VoiceServerFrame.EndTurnFrame)
        {
            _since = null;
            return false;
        }
        if (f is not (VoiceServerFrame.Ready or VoiceServerFrame.Latency or VoiceServerFrame.Other)) Dropped++;
        return true;
    }
}
