namespace Jarvis.Core.Link;

/// Reconnect delays: 250 ms, 500 ms, 1 s, then 2 s until a hello resets it.
public sealed class Backoff
{
    public static readonly TimeSpan[] Steps =
    {
        TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(500), TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2),
    };

    private int _i;

    public TimeSpan Next() => Steps[Math.Min(_i++, Steps.Length - 1)];

    public void Reset() => _i = 0;
}
