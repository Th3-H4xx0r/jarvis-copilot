namespace Jarvis.Tests.Fakes;

/// A TimeProvider that only moves when told to. Timers fire synchronously inside `Advance`.
public sealed class ManualTime : TimeProvider
{
    private readonly object _lock = new();
    private readonly List<ManualTimer> _timers = new();
    private DateTimeOffset _now;

    public ManualTime(DateTimeOffset? start = null) => _now = start ?? TestClock.T0;

    public override DateTimeOffset GetUtcNow() { lock (_lock) return _now; }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override long GetTimestamp() => GetUtcNow().UtcTicks;

    /// Timers created and not disposed (a disposed or fired one-shot timer no longer counts).
    public int ActiveTimers { get { lock (_lock) return _timers.Count(t => t.Due != null); } }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var t = new ManualTimer(this, callback, state);
        lock (_lock) _timers.Add(t);
        t.Change(dueTime, period);
        return t;
    }

    public void Advance(TimeSpan by)
    {
        DateTimeOffset end;
        lock (_lock) end = _now + by;
        while (true)
        {
            ManualTimer? next;
            lock (_lock)
            {
                next = _timers.Where(t => t.Due != null && t.Due <= end).OrderBy(t => t.Due).FirstOrDefault();
                if (next == null) { _now = end; break; }
                _now = next.Due!.Value;
                next.Due = next.Period is { } p && p > TimeSpan.Zero && p != Timeout.InfiniteTimeSpan ? _now + p : null;
            }
            next.Fire();
        }
    }

    private sealed class ManualTimer : ITimer
    {
        private readonly ManualTime _owner;
        private readonly TimerCallback _cb;
        private readonly object? _state;
        public DateTimeOffset? Due;
        public TimeSpan? Period;

        public ManualTimer(ManualTime owner, TimerCallback cb, object? state) { _owner = owner; _cb = cb; _state = state; }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            lock (_owner._lock)
            {
                Period = period;
                Due = dueTime == Timeout.InfiniteTimeSpan ? null : _owner._now + dueTime;
            }
            return true;
        }

        public void Fire() => _cb(_state);

        public void Dispose() { lock (_owner._lock) { Due = null; _owner._timers.Remove(this); } }

        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}
