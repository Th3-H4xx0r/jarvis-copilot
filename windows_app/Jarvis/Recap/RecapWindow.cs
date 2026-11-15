using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Http;
using Jarvis.Core.Model;
using Jarvis.Ui;

namespace Jarvis.Recap;

/// The week's recap: time spent, sessions, files and lines changed, commands, approvals, plus
/// the highlights. Opens from the tray or Jarvis's `island` tab "recap". JcLoader while loading.
public sealed class RecapWindow : Window
{
    private readonly ApiClient _api;
    private readonly ContentControl _body = new();

    public RecapWindow(ApiClient api)
    {
        _api = api;
        Title = "Your week with your agents";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize;
        Background = Th.B("JcBackground");
        Content = new Border { Padding = new Thickness(20), Child = _body };
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        _body.Content = Th.Row(10, new JcLoader { Size = 18 }, Th.Text("Adding up your week…", 13, "JcTextDim"));
        try
        {
            var tz = -(int)TimeZoneInfo.Local.GetUtcOffset(DateTime.UtcNow).TotalMinutes;
            var json = await _api.GetAsync($"/api/coding/agents/recap?days=7&tz={tz}", TimeSpan.FromSeconds(15));
            Show(Core.Model.Recap.FromJson(json));
        }
        catch (ApiException e)
        {
            _body.Content = Th.Text($"Couldn't load the recap: {e.Error}", 13, "JcTextDim", wrap: true);
        }
    }

    private void Show(Core.Model.Recap r)
    {
        if (r.IsEmpty)
        {
            _body.Content = Th.Text("No agent time this week yet.", 14, "JcTextDim");
            return;
        }
        var col = new StackPanel();
        col.Children.Add(Th.Text("This week", 12, "JcTextDim"));
        col.Children.Add(Th.Text(r.Time, 30, bold: true));
        col.Children.Add(Th.Text($"{r.Sessions} sessions · {r.Files} files · +{r.Added} −{r.Removed}", 13, "JcTextDim"));
        col.Children.Add(Th.Text($"{r.Commands} commands · {r.Approved} approved · {r.Denied} denied · {r.Answered} answered", 13, "JcTextDim"));
        foreach (var h in r.Highlights)
        {
            var row = Th.Card(Th.Column(2, Th.Text(h.Label, 11, "JcTextDim"), Th.Text(h.Value, 14, bold: true)), pad: 10);
            row.Margin = new Thickness(0, 8, 0, 0);
            col.Children.Add(row);
        }
        _body.Content = col;
    }
}
