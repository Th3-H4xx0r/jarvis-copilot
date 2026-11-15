using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Core.Prefs;
using Jarvis.Core.Voice;
using Jarvis.Ui;
using Jarvis.Voice;

namespace Jarvis.Orb;

/// The orb on the desktop: 120 px, no-activate, drag to move (remembered), click to talk. Hidden
/// while the presentation gate is closed (a game in front) and back after. Ctrl+Alt+D toggles it.
public sealed class DesktopOrbWindow : NoActivateWindow
{
    public const string OriginKey = "orb.desktopOrigin";
    private readonly PrefsStore _prefs;
    private readonly PresentationGate _gate;
    private readonly VoiceController _voice;
    private readonly OrbView _orb = new();
    private Point _downAt;

    public DesktopOrbWindow(PrefsStore prefs, PresentationGate gate, VoiceController voice, IslandPresenter island)
    {
        _prefs = prefs;
        _gate = gate;
        _voice = voice;
        Title = "Jarvis orb";
        Width = Height = 120;
        Background = Brushes.Transparent;
        Content = _orb;
        Cursor = Cursors.Hand;

        if (ParseOrigin(prefs.Get<string>(OriginKey, "")) is { } o) { Left = o.X; Top = o.Y; }
        else { Left = SystemParameters.WorkArea.Right - 160; Top = SystemParameters.WorkArea.Bottom - 160; }

        MouseLeftButtonDown += (_, e) =>
        {
            _downAt = new Point(Left, Top);
            DragMove();
            if (Math.Abs(Left - _downAt.X) + Math.Abs(Top - _downAt.Y) < 4)
            {
                if (_voice.State.IsActive()) _ = _voice.StopAsync();
                else { _ = _voice.StartConversationAsync("orb"); island.Open(IslandTab.Voice); }
            }
            else
            {
                _prefs.Set(OriginKey, string.Create(CultureInfo.InvariantCulture, $"{Left:0},{Top:0}"));
            }
        };
        voice.Changed += () => Dispatcher.BeginInvoke(() => { _orb.Mood = _voice.Mood; _orb.Level = _voice.InputLevel; });
        prefs.Changed += k => { if (k == PrefKeys.OrbDesktop.Name) Update(); };
    }

    internal static Point? ParseOrigin(string raw)
    {
        var parts = raw.Split(',');
        return parts.Length == 2
            && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)
            && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)
            ? new Point(x, y) : null;
    }

    /// Show when switched on and allowed to draw; hide otherwise.
    public void Update()
    {
        if (_prefs.Get(PrefKeys.OrbDesktop) && _gate.CanPresent) { if (!IsVisible) Show(); }
        else if (IsVisible) Hide();
    }

    public void Toggle() => _prefs.Set(PrefKeys.OrbDesktop, !_prefs.Get(PrefKeys.OrbDesktop));
}
