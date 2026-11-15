using System.Windows;
using Jarvis.Core.Input;
using Jarvis.Core.Prefs;
using Jarvis.Ui;
using Jarvis.Voice.Audio;

namespace Jarvis.Settings;

/// Talk & wake word: "Hey Jarvis" on/off, the push-to-talk key (Right Alt / Right Ctrl /
/// F13–F24, never the Flow key), and the speaker and mic Jarvis follows (the Windows defaults).
public static class TalkPane
{
    public static FrameworkElement Build(PrefsStore prefs, AudioEndpoints endpoints, Func<bool> wakeListening)
    {
        var p = Pane.Page("Talk & wake word", "Say \"Hey Jarvis\", or hold a key and talk. Voice still answers while you play, as audio only.");
        p.Children.Add(Pane.Section("Wake word"));
        var status = Th.Text("", 12, "JcTextDim");
        void Status() => status.Text = !prefs.Get(PrefKeys.WakeEnabled) ? "Off." : wakeListening() ? "Listening for \"Hey Jarvis\" on this PC." : "Starts when Jarvis connects.";
        p.Children.Add(Th.Switch("Listen for \"Hey Jarvis\"", prefs.Get(PrefKeys.WakeEnabled), v => { prefs.Set(PrefKeys.WakeEnabled, v); Status(); }));
        p.Children.Add(status);

        p.Children.Add(Pane.Section("Push to talk"));
        var clash = Th.Text("", 12, "JcAmber", wrap: true);
        void Clash() => clash.Text = HoldKeys.Problem(prefs.Get(PrefKeys.TalkKey), prefs.Get(PrefKeys.FlowKey), prefs.Get(PrefKeys.FlowEnabled)) ?? "";
        var keys = new List<(string, string)> { ("", "Off") };
        keys.AddRange(HoldKeys.Choices.Select(k => (k, HoldKeys.Display(k))));
        p.Children.Add(Pane.Labeled("Hold to talk", Pane.Picker(keys, prefs.Get(PrefKeys.TalkKey), v => { prefs.Set(PrefKeys.TalkKey, v); Clash(); }),
            "Held for a moment before it listens, so the key still works for typing."));
        p.Children.Add(clash);

        p.Children.Add(Pane.Section("Devices"));
        var (render, capture) = endpoints.Defaults();
        p.Children.Add(Pane.Labeled("Speaker", Th.Text(Name(render), 13, "JcTextDim")));
        p.Children.Add(Pane.Labeled("Microphone", Th.Text(Name(capture), 13, "JcTextDim")));
        p.Children.Add(Th.Text("Jarvis follows Windows' default devices and moves when you plug in a headset.", 12, "JcTextFaint", wrap: true));
        Status();
        Clash();
        return p;
    }

    private static string Name(string id) => id.Length == 0 ? "None" : AudioEndpoints.FriendlyName(id) is { Length: > 0 } n ? n : "Default";
}
