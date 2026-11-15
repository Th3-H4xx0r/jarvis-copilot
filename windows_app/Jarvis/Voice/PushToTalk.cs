using System.Diagnostics;
using System.Windows.Threading;
using Jarvis.Core.Input;
using Jarvis.Core.Link;
using Jarvis.Core.Prefs;
using Jarvis.Core.Voice;
using Jarvis.Core.Wake;
using Jarvis.Input;
using Jarvis.Platform;

namespace Jarvis.Voice;

/// Push to talk on the held key from Settings → Talk (Raw Input, no hook): held 0.15 s it
/// starts a turn, let go sends it. Tells jc-client which display it was held on (talk_screen).
/// Another key while waiting means it was a modifier for typing (AltGr), so nothing starts.
public sealed class PushToTalk
{
    private const string Name = "talk";
    private readonly HoldKeyWatcher _keys;
    private readonly VoiceController _voice;
    private readonly PrefsStore _prefs;
    private readonly IJcLink _link;
    private readonly DispatcherTimer _wait = new() { Interval = TimeSpan.FromSeconds(TalkKeyLogic.StartDelay + 0.01) };
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private TalkKeyLogic _logic;

    public PushToTalk(HoldKeyWatcher keys, VoiceController voice, PrefsStore prefs, IJcLink link)
    {
        _keys = keys;
        _voice = voice;
        _prefs = prefs;
        _link = link;
        keys.Changed += (name, down) => { if (name == Name) OnKey(down); };
        keys.OtherKey += () => Apply(_logic.OtherKey());
        _wait.Tick += (_, _) => { _wait.Stop(); Apply(_logic.Tick(Now)); };
        prefs.Changed += k => { if (k is "talk.key" or "flow.key" or "flow.enabled") Sync(); };
        Sync();
    }

    /// The turn started (the island's Voice view opens, through the gate).
    public event Action? Started;

    private double Now => _clock.Elapsed.TotalSeconds;

    public void Sync()
    {
        var key = _prefs.Get(PrefKeys.TalkKey);
        var clash = HoldKeys.Problem(key, _prefs.Get(PrefKeys.FlowKey), _prefs.Get(PrefKeys.FlowEnabled)) != null;
        if (HoldKeys.Vk(key) is { } vk && !clash) _keys.Watch(Name, vk);
        else _keys.Unwatch(Name);
    }

    private void OnKey(bool down)
    {
        if (down)
        {
            Apply(_logic.KeyDown(Now));
            _wait.Start();
        }
        else
        {
            _wait.Stop();
            Apply(_logic.KeyUp(Now));
        }
    }

    private void Apply(TalkKeyLogic.Action a)
    {
        switch (a)
        {
            case TalkKeyLogic.Action.Start:
                TellScreen();
                _ = _voice.PushToTalkDownAsync();
                Started?.Invoke();
                break;
            case TalkKeyLogic.Action.Send:
                _ = _voice.PushToTalkUpAsync();
                break;
        }
    }

    private void TellScreen()
    {
        var mons = Monitors.All().Select(m => (m.Name, m.Bounds)).ToList();
        if (TalkScreen.Pick(mons, Monitors.Cursor()) is { } m) _ = _link.RequestAsync(TalkScreen.Message(m.Bounds, m.Name));
    }
}
