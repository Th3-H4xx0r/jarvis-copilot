using System.Windows.Threading;

namespace Jarvis.Platform;

/// A TimeProvider whose timers fire on the WPF Dispatcher. AppState, the PresentationGate and
/// the island presenter all run on the Dispatcher, so their timers must too (the system
/// provider fires on pool threads). A timer only exists while Core asked for one: no idle ticks.
public sealed class DispatcherTimeProvider : TimeProvider
{
    private readonly Dispatcher _dispatcher;

    public DispatcherTimeProvider(Dispatcher dispatcher) => _dispatcher = dispatcher;

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
        new Timer(_dispatcher, callback, state, dueTime, period);

    private sealed class Timer : ITimer
    {
        private readonly DispatcherTimer _timer;
        private readonly TimerCallback _callback;
        private readonly object? _state;
        private TimeSpan _period;
        private bool _disposed;

        public Timer(Dispatcher dispatcher, TimerCallback callback, object? state, TimeSpan due, TimeSpan period)
        {
            _callback = callback;
            _state = state;
            _timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher);
            _timer.Tick += OnTick;
            Change(due, period);
        }

        private void OnTick(object? sender, EventArgs e)
        {
            if (_period > TimeSpan.Zero && _period != Timeout.InfiniteTimeSpan) _timer.Interval = _period;
            else _timer.Stop();
            _callback(_state);
        }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            if (_disposed) return false;
            _period = period;
            _timer.Stop();
            if (dueTime == Timeout.InfiniteTimeSpan) return true;
            _timer.Interval = dueTime < TimeSpan.Zero ? TimeSpan.Zero : dueTime;
            _timer.Start();
            return true;
        }

        public void Dispose()
        {
            _disposed = true;
            _timer.Stop();
            _timer.Tick -= OnTick;
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
