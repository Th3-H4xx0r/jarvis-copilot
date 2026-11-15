using System.Text.Json.Nodes;

namespace Jarvis.Core.Update;

/// When to look for an update and whether to show the card: on hello (a launch), on the
/// `app_update` push, and every 15 minutes while connected; Later snoozes one build (UpdateGate).
/// An unstamped dev build (no version.json) is never offered anything.
public sealed class UpdateCoordinator
{
    public static readonly TimeSpan PollEvery = TimeSpan.FromMinutes(15);

    private readonly Func<Task<UpdateOffer?>> _check;
    private readonly TimeProvider _time;
    private readonly bool _stamped;
    private UpdateGate _gate;
    private bool _launched;

    public UpdateCoordinator(Func<Task<UpdateOffer?>> check, AppVersion current, TimeProvider? time = null)
    {
        _check = check;
        _time = time ?? TimeProvider.System;
        _stamped = current != AppVersion.Unstamped;
    }

    public UpdateOffer? Offer { get; private set; }
    public event Action<UpdateOffer>? Show;

    /// AppState.AppUpdateSignal: null = a hello, else the `app_update` topic's data.
    public Task SignalAsync(JsonObject? topic) =>
        CheckAsync(topic == null ? (_launched ? UpdateGate.Trigger.Poll : UpdateGate.Trigger.Launch) : UpdateGate.Trigger.Push);

    public Task PollAsync() => CheckAsync(UpdateGate.Trigger.Poll);

    /// He came back to the PC (the island opened): a snoozed build may show again.
    public Task ActivationAsync() => CheckAsync(UpdateGate.Trigger.Activation);

    public void Later()
    {
        if (Offer is { } o) _gate.Later(o.Build, _time.GetUtcNow());
    }

    private async Task CheckAsync(UpdateGate.Trigger t)
    {
        if (t == UpdateGate.Trigger.Launch) _launched = true;
        if (!_stamped) return;
        if (await _check().ConfigureAwait(false) is not { } offer) return;
        Offer = offer;
        if (_gate.ShouldShow(offer.Build, t, _time.GetUtcNow())) Show?.Invoke(offer);
    }
}
