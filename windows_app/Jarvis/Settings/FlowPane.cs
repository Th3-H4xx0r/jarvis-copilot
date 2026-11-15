using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Flow;
using Jarvis.Core.Input;
using Jarvis.Core.Prefs;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Flow: on/off, the key, the default style and per-app styles, the dictionary, replacements,
/// snippets, the clean-up switch, and the numbers.
public static class FlowPane
{
    public static FrameworkElement Build(PrefsStore prefs, FlowStore store, FlowController flow)
    {
        var s = store.LoadSettings();
        var p = Pane.Page("Flow", "Hold a key, speak, let go: the words are typed where your cursor is. Two quick taps for hands-free.");
        void Save(FlowSettings next) { s = next; store.SaveSettings(next); }

        p.Children.Add(Pane.Section("Dictation"));
        p.Children.Add(Th.Switch("Flow is on", prefs.Get(PrefKeys.FlowEnabled), v => prefs.Set(PrefKeys.FlowEnabled, v)));
        var clash = Th.Text("", 12, "JcAmber", wrap: true);
        void Clash() => clash.Text = HoldKeys.Problem(prefs.Get(PrefKeys.TalkKey), prefs.Get(PrefKeys.FlowKey), prefs.Get(PrefKeys.FlowEnabled)) is { } x
            ? x + " Pick another key for one of them." : "";
        var keys = HoldKeys.Choices.Take(5).Select(k => (k, HoldKeys.Display(k)));
        p.Children.Add(Pane.Labeled("Key to hold", Pane.Picker(keys, prefs.Get(PrefKeys.FlowKey), v => { prefs.Set(PrefKeys.FlowKey, v); Clash(); })));
        p.Children.Add(clash);
        var styles = Enum.GetValues<FlowStyle>().Select(v => (v.ToString(), v switch
        {
            FlowStyle.verbatim => "As said",
            FlowStyle.natural => "Natural",
            _ => "Polished",
        }));
        p.Children.Add(Pane.Labeled("Style", Pane.Picker(styles, s.DefaultStyle.ToString(), v => Save(s with { DefaultStyle = Enum.Parse<FlowStyle>(v) })),
            "As said keeps your words exactly; Natural drops the uh's; Polished writes clean sentences."));
        p.Children.Add(Th.Switch("Clean up with a Jarvis model", s.CleanupOn, v => Save(s with { CleanupOn = v })));

        p.Children.Add(Pane.Section("Dictionary (one word per line)"));
        var words = Th.Input("Words Flow should spell your way", multiline: true);
        words.Height = 90;
        words.Text = string.Join("\n", s.Words);
        words.LostFocus += (_, _) => Save(s with { Words = Lines(words.Text) });
        p.Children.Add(words);

        p.Children.Add(Pane.Section("Replacements (heard => written, one per line)"));
        var reps = Th.Input("cloud code => Claude Code", multiline: true);
        reps.Height = 90;
        reps.Text = string.Join("\n", s.Replacements.Select(r => $"{r.From} => {r.To}"));
        reps.LostFocus += (_, _) => Save(s with { Replacements = Pairs(reps.Text).Select(x => new FlowReplacement(x.A, x.B)).ToList() });
        p.Children.Add(reps);

        p.Children.Add(Pane.Section("Snippets (say => text, one per line)"));
        var snips = Th.Input("my email => me@example.com", multiline: true);
        snips.Height = 90;
        snips.Text = string.Join("\n", s.Snippets.Select(x => $"{x.Trigger} => {x.Text.Replace("\n", "\\n")}"));
        snips.LostFocus += (_, _) => Save(s with { Snippets = Pairs(snips.Text).Select(x => new FlowSnippet(x.A, x.B.Replace("\\n", "\n"))).ToList() });
        p.Children.Add(snips);

        p.Children.Add(Pane.Section("Per app"));
        foreach (var app in s.Styles)
            p.Children.Add(Pane.Labeled(app.Exe, Th.Text(app.Style.ToString(), 12, "JcTextDim")));

        p.Children.Add(Pane.Section("Your numbers"));
        var stats = store.LoadStats();
        p.Children.Add(Th.Text($"{stats.TotalWords + flow.Stats.TotalWords} words dictated.", 13, "JcTextDim"));
        Clash();
        return p;
    }

    private static List<string> Lines(string text) =>
        text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();

    private static List<(string A, string B)> Pairs(string text) =>
        Lines(text).Select(l => l.Split("=>", 2)).Where(x => x.Length == 2 && x[0].Trim().Length > 0)
            .Select(x => (x[0].Trim(), x[1].Trim())).ToList();
}
