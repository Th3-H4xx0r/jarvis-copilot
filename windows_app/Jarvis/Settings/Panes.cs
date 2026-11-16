using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Jarvis.Core.Input;
using Mods = Jarvis.Core.Input.ModifierKeys;
using WpfMods = System.Windows.Input.ModifierKeys;
using Jarvis.Core.Power;
using Jarvis.Core.Prefs;
using Jarvis.Core.Settings;
using Jarvis.Core.Sounds;
using Jarvis.Core.Startup;
using Jarvis.Core.State;
using Jarvis.Input;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Shared layout for native panes, after the Mac's grouped Form: the title goes in the window's
/// header (the Mac's navigation title), sections are headers over rounded cards of rows
/// (SettingsForm lays them out), labels on the left and controls on the right.
internal static class Pane
{
    public sealed record Header(string Title, string? Subtitle);

    public static StackPanel Page(string title, string? subtitle = null) =>
        new() { Tag = new Header(title, subtitle) };

    public static TextBlock Section(string title) =>
        new() { Text = title, Tag = SettingsForm.SectionTag };

    /// Small grey text under a section's card (a Form section footer).
    public static TextBlock Footer(string text)
    {
        var t = Th.Text(text, 11.5, "JcSetSecondary", wrap: true);
        t.Tag = SettingsForm.FooterTag;
        return t;
    }

    /// Several parts as one (an Extras entry with its own section): spliced into the page.
    public static StackPanel Group(params UIElement[] parts)
    {
        var p = new StackPanel { Tag = SettingsForm.GroupTag };
        foreach (var x in parts) p.Children.Add(x);
        return p;
    }

    public static FrameworkElement Labeled(string label, UIElement control, string? hint = null)
    {
        var name = Th.Text(label, 13, "JcSetLabel", wrap: true);
        var left = hint == null ? (UIElement)name : Th.Column(2, name, Th.Text(hint, 11.5, "JcSetSecondary", wrap: true));
        var row = new DockPanel { LastChildFill = true };
        if (control is FrameworkElement fe)
        {
            fe.VerticalAlignment = VerticalAlignment.Center;
            fe.Margin = new Thickness(16, 0, 0, 0);
        }
        DockPanel.SetDock(control, Dock.Right);
        row.Children.Add(control);
        row.Children.Add(left);
        return SettingsForm.Row(row);
    }

    public static ComboBox Picker(IEnumerable<(string Value, string Label)> items, string current, Action<string> changed)
    {
        var c = new ComboBox { MinWidth = 160 };
        foreach (var (v, l) in items) c.Items.Add(new ComboBoxItem { Content = l, Tag = v, IsSelected = v == current });
        c.SelectionChanged += (_, _) => { if (c.SelectedItem is ComboBoxItem { Tag: string v }) changed(v); };
        return c;
    }
}

/// General: island screen, hover/idle/working behaviour, sounds, start at login, the island
/// chat choice (filled by Task 15), and the notes on what Windows can't do.
public static class GeneralPane
{
    /// Task 15 adds the island chat choice; Task 16 the Holo Drop firewall button.
    public static readonly List<Func<FrameworkElement>> Extras = new();

    public static FrameworkElement Build(PrefsStore prefs)
    {
        var p = Pane.Page("General");
        p.Children.Add(Pane.Section("Island"));
        var screens = new List<(string, string)> { ("primary", "Main display"), ("followMouse", "Follow the mouse") };
        screens.AddRange(Monitors.All().Select(m => ("display:" + m.Name, m.Name.Replace(@"\\.\", "") + (m.Primary ? " (main)" : ""))));
        p.Children.Add(Pane.Labeled("Show the island on", Pane.Picker(screens, prefs.Get(PrefKeys.IslandDisplay), v => prefs.Set(PrefKeys.IslandDisplay, v))));
        p.Children.Add(Th.Switch("Open when the mouse is over it", prefs.Get(PrefKeys.IslandOpenOnHover), v => prefs.Set(PrefKeys.IslandOpenOnHover, v)));
        p.Children.Add(Th.Switch("Hide when nothing needs you", prefs.Get(PrefKeys.IslandHideWhenIdle), v => prefs.Set(PrefKeys.IslandHideWhenIdle, v)));
        p.Children.Add(Th.Switch("Keep it up while agents work", prefs.Get(PrefKeys.IslandShowWhileWorking), v => prefs.Set(PrefKeys.IslandShowWhileWorking, v)));

        p.Children.Add(Pane.Section("Sounds"));
        p.Children.Add(Th.Switch("Play sounds", prefs.Get(PrefKeys.SoundOn), v => prefs.Set(PrefKeys.SoundOn, v)));
        var vol = new Slider { Minimum = 0, Maximum = 1, Value = prefs.Get(PrefKeys.SoundVolume), Width = 200 };
        vol.ValueChanged += (_, e) => prefs.Set(PrefKeys.SoundVolume, Math.Round(e.NewValue, 2));
        p.Children.Add(Pane.Labeled("Volume", vol));
        p.Children.Add(Pane.Labeled("Your own sounds", Th.Button("Open sounds folder", () =>
        {
            System.IO.Directory.CreateDirectory(SoundFiles.DefaultOverrideDir);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{SoundFiles.DefaultOverrideDir}\"") { UseShellExecute = true });
        }), "needs-you, finished, failed, started or decided as .wav, .mp3 or .m4a"));

        p.Children.Add(Pane.Section("Startup"));
        var reg = new WinRegistry();
        p.Children.Add(Th.Switch("Start Jarvis when you sign in", StartupRegistration.IsOn(reg), on =>
        {
            if (Environment.ProcessPath is { } exe) StartupRegistration.Set(reg, exe, on);
        }));

        foreach (var extra in Extras) p.Children.Add(extra());

        p.Children.Add(Pane.Section("On Windows"));
        foreach (var note in GeneralNotes.All)
        {
            var t = Th.Text(note, 12, "JcTextDim", wrap: true);
            t.Margin = new Thickness(0, 2, 0, 2);
            p.Children.Add(t);
        }
        return p;
    }
}

/// Agents: per agent, preview the exact hook change (a coloured diff), then Install writes only
/// that change; Uninstall; approvals/instructions shown read-only from jc-client's config.
public static class AgentsPane
{
    public static FrameworkElement Build(AppState state)
    {
        var flow = new HooksFlow(state);
        var p = Pane.Page("Agents", "Jarvis tracks your coding agents through their hooks. Look at the change first; Install writes exactly that.");
        var statusPanel = new StackPanel();
        var diffBox = new StackPanel();
        var error = Th.Text("", 12, "JcAmber", wrap: true);
        var loader = new JcLoader { Size = 16, Visibility = Visibility.Collapsed };

        var agentPick = Pane.Picker(HooksFlow.Agents.Select(a => (a, Core.Model.AgentSession.DisplayName(a))), flow.Agent, a =>
        {
            flow.Agent = a;
            _ = flow.PreviewAsync();
        });
        var statusline = Th.Switch("Also show plan usage in Claude Code's status line", flow.StatusLine, v => { flow.StatusLine = v; _ = flow.PreviewAsync(); });
        var buttons = Th.Row(8,
            Th.Button("Install", () => _ = flow.InstallAsync(), primary: true),
            Th.Button("Look again", () => _ = flow.PreviewAsync()),
            Th.Button("Uninstall", () => _ = flow.UninstallAsync()),
            loader);

        void Render()
        {
            loader.Visibility = flow.Busy ? Visibility.Visible : Visibility.Collapsed;
            error.Text = flow.Error ?? "";
            diffBox.Children.Clear();
            foreach (var (kind, text) in HooksFlow.DiffLines(flow.Diff))
                diffBox.Children.Add(Th.Text(text, 12, kind == '+' ? "JcText" : kind == '-' ? "JcTextFaint" : "JcTextDim", mono: true));
            if (flow.Diff.Length == 0) diffBox.Children.Add(Th.Text(flow.Token == null ? "Nothing to change." : "", 12, "JcTextDim"));
            statusPanel.Children.Clear();
            foreach (var a in HooksFlow.Agents)
                statusPanel.Children.Add(Pane.Labeled(Core.Model.AgentSession.DisplayName(a), Th.Text(flow.Status.TryGetValue(a, out var s) ? s : "…", 12, "JcTextDim")));
        }
        flow.Changed += () => p.Dispatcher.BeginInvoke(Render);

        p.Children.Add(Pane.Section("Status"));
        p.Children.Add(statusPanel);
        p.Children.Add(Pane.Section("Install hooks"));
        p.Children.Add(Pane.Labeled("Agent", agentPick));
        p.Children.Add(statusline);
        var diffCard = Th.Card(new ScrollViewer { Content = diffBox, MaxHeight = 260, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto }, "JcSurface");
        diffCard.Margin = new Thickness(0, 8, 0, 8);
        p.Children.Add(diffCard);
        p.Children.Add(error);
        p.Children.Add(buttons);

        p.Children.Add(Pane.Section("From jc-client"));
        p.Children.Add(Pane.Labeled("Approvals on the island", Th.Text(state.ApprovalsOn ? "On" : "Off", 13, "JcTextDim")));
        p.Children.Add(Pane.Labeled("Instructions from Jarvis", Th.Text(state.InstructionsOn ? "On" : "Off", 13, "JcTextDim")));

        Render();
        _ = flow.RefreshStatusAsync();
        _ = flow.PreviewAsync();
        return p;
    }
}

/// PC power: Keep awake, what holds the PC awake, whether it can be woken, and the last
/// sleep/wake relay.
public static partial class PcPowerPane
{
    public static FrameworkElement Build(PcPowerClient power, PowerRelay relay, Unlock.PcUnlock? unlock = null)
    {
        var p = Pane.Page("PC power", "Keep the PC reachable from your phone, and see whether it can be woken.");
        var held = Th.Text("", 13, "JcTextDim", wrap: true);
        var wake = Th.Text("", 13, "JcTextDim", wrap: true);
        var detail = Th.Text("", 11, "JcTextFaint", wrap: true);
        var last = Th.Text("", 12, "JcTextFaint");
        var updating = false;
        var keep = Th.Switch("Keep this PC awake (the screen can still turn off)", false, on =>
        {
            if (!updating) _ = power.SetKeepAwakeAsync(on);
        });

        void Render(PcPowerState? s)
        {
            updating = true;
            keep.IsChecked = s?.KeepAwake ?? false;
            updating = false;
            held.Text = s?.HeldLine ?? "Jarvis isn't running on this PC.";
            wake.Text = s?.WakeSentence ?? "";
            detail.Text = s is { WakeDetail.Length: > 0 } ? s.WakeDetail : "";
            last.Text = relay.LastEventAt is { } at
                ? $"Last {(relay.LastEvent == "did_wake" ? "wake" : "sleep")}: {at.ToLocalTime():ddd HH:mm}"
                : "No sleep or wake since Jarvis started.";
        }
        power.Changed += s => p.Dispatcher.BeginInvoke(() => Render(s));

        p.Children.Add(Pane.Section("Awake"));
        p.Children.Add(keep);
        p.Children.Add(held);
        p.Children.Add(Pane.Section("Waking from your phone"));
        p.Children.Add(wake);
        p.Children.Add(detail);
        p.Children.Add(Pane.Section("Sleep and wake"));
        p.Children.Add(last);
        if (unlock != null) AddUnlock(p, unlock);
        foreach (var extra in Extras) p.Children.Add(extra());
        Render(power.Last);
        _ = power.RefreshAsync();
        return p;
    }
}

public static partial class PcPowerPane
{
    /// Sections other features add (PC Stats).
    public static readonly List<Func<FrameworkElement>> Extras = new();

    /// Unlock from your iPhone: trust its Face ID key, save the Windows password or PIN (kept
    /// encrypted for this Windows account), install the helper that types it on the lock screen.
    private static void AddUnlock(StackPanel p, Unlock.PcUnlock unlock)
    {
        // Rows re-built in place (already Form rows inside).
        var keyRow = new ContentControl { Tag = SettingsForm.RowTag };
        var passRow = new ContentControl { Tag = SettingsForm.RowTag };
        var helperRow = new ContentControl { Tag = SettingsForm.RowTag };
        var note = Th.Text("", 12, "JcSetSecondary", wrap: true);

        void Render()
        {
            keyRow.Content = unlock.PinnedKey is { } k
                ? Pane.Labeled("Your iPhone", Th.Row(10, Th.Text($"Trusted · code {Core.Unlock.UnlockApproval.Fingerprint(k)}", 13, "JcSetSecondary"),
                    Th.Button("Trust again", () => _ = Trust())), "Only a Face ID yes signed by this iPhone unlocks the PC.")
                : Pane.Labeled("Your iPhone", Th.Button("Trust my iPhone", () => _ = Trust(), primary: true),
                    "Uses the Face ID key your iPhone set up for Jarvis approvals.");
            var box = new PasswordBox { Width = 180 };
            passRow.Content = Pane.Labeled("Windows password or PIN",
                Th.Row(8, box, Th.Button(unlock.HasPassword ? "Replace" : "Save", () =>
                {
                    if (box.Password.Length == 0) { note.Text = "Type the password or PIN you use on the lock screen."; return; }
                    unlock.SavePassword(box.Password);
                    box.Clear();
                    note.Text = "Saved, encrypted for your Windows account.";
                }), unlock.HasPassword ? Th.Button("Forget", unlock.ForgetPassword) : new TextBlock()),
                unlock.HasPassword ? "Saved. What you type on the lock screen." : "What you type on the lock screen. Kept encrypted on this PC; it never leaves it.");
            var installed = Unlock.PcUnlock.HelperInstalled;
            helperRow.Content = Pane.Labeled("Unlock helper",
                installed ? Th.Text(Core.Unlock.UnlockSetup.HelperLine(true), 13, "JcSetSecondary") : Th.Button("Install", () => _ = Install()),
                "Windows lets nothing type on its lock screen except a system helper. Installing asks Face ID on your iPhone, then Windows' Yes.");
        }

        async Task Trust()
        {
            try
            {
                var key = await unlock.FetchKeyAsync();
                if (string.IsNullOrEmpty(key)) { note.Text = "Your iPhone hasn't set up Face ID approvals yet."; return; }
                unlock.Pin(key);
                note.Text = $"Trusted. Code {Core.Unlock.UnlockApproval.Fingerprint(key)}.";
            }
            catch (Core.Http.ApiException e) { note.Text = $"Couldn't get your iPhone's key: {e.Error}"; }
        }

        async Task Install()
        {
            var r = await unlock.InstallHelperAsync();
            note.Text = r.Message;
        }

        unlock.Changed += () => p.Dispatcher.BeginInvoke(Render);
        p.Children.Add(Pane.Section("Unlock from your iPhone"));
        p.Children.Add(keyRow);
        p.Children.Add(passRow);
        p.Children.Add(helperRow);
        p.Children.Add(note);
        p.Children.Add(Pane.Footer("Tap Unlock on the PC's card in Agents on your iPhone and approve with Face ID. The helper types only when the lock screen is showing."));
        Render();
    }
}

/// Shortcuts: each action's chord, Record (the next chord pressed while this window is in
/// front), Off, and Default. Hotkeys are unbound while recording.
public static class ShortcutsPane
{
    /// Task 17 adds the "Mouse fling" toggle here.
    public static readonly List<Func<FrameworkElement>> Extras = new();

    public static FrameworkElement Build(PrefsStore prefs, HotKeyCenter hotKeys, Action rebind)
    {
        var p = Pane.Page("Shortcuts", "Global chords work in any app. A chord another app already owns won't bind.");
        var failures = new Dictionary<ShortcutAction, string>();
        hotKeys.Failed += (a, s) => failures[a] = $"{s.Display()} is taken by another app.";
        var rows = new StackPanel();
        ShortcutAction? recording = null;

        void Render()
        {
            rows.Children.Clear();
            foreach (var a in ShortcutActions.All)
            {
                var action = a;
                var current = a.Binding(prefs);
                var label = recording == a ? "Press a chord…" : current?.Display() ?? "Off";
                var chord = Th.Text(label, 13, recording == a ? "JcAmber" : current == null ? "JcTextFaint" : "JcText");
                chord.MinWidth = 130;
                var controls = Th.Row(6, chord,
                    Th.Button("Record", () => { recording = action; hotKeys.Suspend(); Render(); }, size: 12),
                    Th.Button("Off", () => { action.SetBinding(prefs, null); Render(); }, size: 12),
                    Th.Button("Default", () => { prefs.Set<string?>(action.PrefKey(), null); rebind(); Render(); }, size: 12));
                rows.Children.Add(Pane.Labeled(a.Title(), controls, failures.TryGetValue(a, out var f) ? f : null));
            }
        }

        p.PreviewKeyDown += (_, e) =>
        {
            if (recording is not { } a) return;
            e.Handled = true;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
            recording = null;
            if (key == Key.Escape) { rebind(); Render(); return; }
            var mods = Mods.None;
            var m = Keyboard.Modifiers;
            if (m.HasFlag(WpfMods.Control)) mods |= Mods.Control;
            if (m.HasFlag(WpfMods.Alt)) mods |= Mods.Alt;
            if (m.HasFlag(WpfMods.Shift)) mods |= Mods.Shift;
            if (m.HasFlag(WpfMods.Windows)) mods |= Mods.Windows;
            var sc = new Shortcut((uint)KeyInterop.VirtualKeyFromKey(key), mods);
            // A plain key alone isn't allowed (it would eat typing); re-parse to apply the rules.
            if (Shortcut.Parse(sc.ToPrefString()) is { } ok) a.SetBinding(prefs, ok);
            rebind();
            Render();
        };
        p.Focusable = true;
        p.Loaded += (_, _) => p.Focus();

        p.Children.Add(rows);
        foreach (var extra in Extras) p.Children.Add(extra());
        Render();
        return p;
    }
}
