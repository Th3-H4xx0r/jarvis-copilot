using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Jarvis.Core.Http;
using Jarvis.Core.PowerInt;
using Jarvis.Ui;

namespace Jarvis.Settings;

/// Power integrations (the Mac's MacPowerPane): one row per integration with its switch and a
/// settings form by kind. Switching off a protected one waits for Face ID on his iPhone; while
/// anything is pending the pane re-lists every 3 s, and only while it is on screen.
public static class PowerPane
{
    public static FrameworkElement Build(PowerApi api)
    {
        var p = Pane.Page("Power integrations", "Built-in features you can switch off. Protected ones ask your iPhone for Face ID first.");
        var list = new StackPanel();
        var status = Th.Text("", 12, "JcTextDim", wrap: true);
        var loader = new JcLoader { Size = 18 };
        p.Children.Add(Th.Row(10, loader, status));
        p.Children.Add(list);
        var poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        IReadOnlyList<PowerRow> rows = Array.Empty<PowerRow>();

        async Task Reload()
        {
            try
            {
                rows = await api.ListAsync();
                status.Text = "";
            }
            catch (ApiException e)
            {
                status.Text = $"Couldn't load the integrations: {e.Error}";
            }
            loader.Visibility = Visibility.Collapsed;
            Render();
            if (rows.Any(r => r.Pending) && p.IsVisible) poll.Start(); else poll.Stop();
        }

        async Task Change(PowerRow row, JsonObject body)
        {
            var r = await api.ChangeAsync(row.Id, body);
            if (r is PowerSetResult.Failed f) status.Text = f.Error;
            if (r is PowerSetResult.Pending) status.Text = "Waiting for Face ID on your iPhone.";
            await Reload();
        }

        void Render()
        {
            list.Children.Clear();
            foreach (var row in rows)
            {
                var r = row;
                var sw = new CheckBox { IsChecked = r.Enabled, IsEnabled = !r.Pending, VerticalAlignment = VerticalAlignment.Center, ToolTip = r.Enabled ? "Switch off" : "Switch on" };
                sw.Click += (_, _) => _ = Change(r, new JsonObject { ["enabled"] = sw.IsChecked == true });
                var name = Th.Row(6, Th.Text(r.Name, 14, bold: true));
                if (r.Protected) name.Children.Add(Th.Text("Face ID", 11, "JcTextFaint"));
                var head = new DockPanel();
                DockPanel.SetDock(sw, Dock.Right);
                head.Children.Add(sw);
                head.Children.Add(Th.Column(2, name, Th.Text(r.Summary, 12, "JcTextDim", wrap: true)));
                var col = new StackPanel();
                col.Children.Add(head);
                if (r.Line.Length > 0) col.Children.Add(Th.Text(r.Line, 12, r.Pending ? "JcAmber" : r.Error != null ? "JcRed" : "JcTextDim", wrap: true));
                if (r.Enabled)
                    foreach (var s in r.SettingsSchema)
                        col.Children.Add(Field(s, r.Settings.TryGetValue(s.Key, out var v) ? v : new PowerValue.None(),
                            value => _ = Change(r, new JsonObject { ["settings"] = new JsonObject { [s.Key] = value } })));
                var card = Th.Card(col, pad: 14);
                card.Margin = new Thickness(0, 10, 0, 0);
                list.Children.Add(card);
            }
        }

        poll.Tick += async (_, _) => await Reload();
        p.IsVisibleChanged += (_, _) => { if (!p.IsVisible) poll.Stop(); };
        _ = Reload();
        return p;
    }

    private static FrameworkElement Field(PowerSetting s, PowerValue v, Action<JsonNode?> set)
    {
        UIElement control;
        switch (s.Kind)
        {
            case PowerSettingKind.Toggle:
            {
                var c = new CheckBox { IsChecked = v is PowerValue.Bool { Value: true } };
                c.Click += (_, _) => set(c.IsChecked == true);
                control = c;
                break;
            }
            case PowerSettingKind.Picker:
            {
                var current = v is PowerValue.Text t ? t.Value : v is PowerValue.Number n ? n.Value.ToString(CultureInfo.InvariantCulture) : "";
                control = Pane.Picker(s.Options.Select(o => (o.Value, o.Label)), current, x => set(x));
                break;
            }
            case PowerSettingKind.Number:
            {
                var box = Th.Input();
                box.Width = 120;
                box.Text = v is PowerValue.Number n ? n.Value.ToString(CultureInfo.InvariantCulture) : "";
                box.LostFocus += (_, _) =>
                {
                    if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return;
                    if (s.Min is { } lo) d = Math.Max(lo, d);
                    if (s.Max is { } hi) d = Math.Min(hi, d);
                    set(d);
                };
                control = Th.Row(6, box, Th.Text(s.Unit, 12, "JcTextDim"));
                break;
            }
            case PowerSettingKind.Secret:
            {
                var box = new PasswordBox { Width = 200, Background = Th.B("JcButton"), Foreground = Th.B("JcText"), BorderThickness = new Thickness(0), Padding = new Thickness(8, 6, 8, 6) };
                box.ToolTip = v is PowerValue.SecretSet { IsSet: true } ? "Set. Type to replace it." : "Not set";
                box.LostFocus += (_, _) => { if (box.Password.Length > 0) set(box.Password); };
                control = box;
                break;
            }
            default:
            {
                var box = Th.Input();
                box.Width = 240;
                box.Text = v is PowerValue.Text t ? t.Value : "";
                box.LostFocus += (_, _) => set(box.Text);
                control = box;
                break;
            }
        }
        return Pane.Labeled(s.Label, control, s.Help.Length > 0 ? s.Help : null);
    }
}
