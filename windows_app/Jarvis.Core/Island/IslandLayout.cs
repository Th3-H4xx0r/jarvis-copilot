namespace Jarvis.Core.Island;

/// The island's sizes in DIPs, the Mac's (IslandLogic.swift IslandLayout / IslandController /
/// IslandRootView) one for one. Windows has no notch, so the resting shape is the size of the
/// MacBook's (184 × 32): the compact island is that plus an ear each side (the orb on the left,
/// what's waiting or working on the right), and the open island hangs 560 wide from it.
public static class IslandLayout
{
    /// The "notch" the island grows from (the Mac's IslandGeometry on a notched MacBook).
    public const double NotchWidth = 184, NotchHeight = 32;
    public const double EarWidth = 40;
    public const double CompactWidth = NotchWidth + 2 * EarWidth, CompactHeight = NotchHeight;
    public const double Width = 560;
    /// The tallest the open island gets (the Mac's panel height); past it the Agents list scrolls.
    public const double MaxHeight = 560;
    /// Bottom corners: the folded pill, the open island.
    public const double CompactRadius = 12, ExpandedRadius = 24;

    /// Where the open island's content starts: under the notch, plus 8.
    public const double TopInset = NotchHeight + 8;
    public const double PadX = 16, PadBottom = 14, Gap = 10;
    public const double TabsHeight = 26;
    public const double RowHeight = 58;

    /// The voice stage under the tab row.
    public const double VoicePanelHeight = 190;
    public const double ChatHeight = 480;

    /// The Music tab's rows: the cover with title and artist, the progress bar, the controls.
    public const double MusicArtwork = 56, MusicProgress = 16, MusicControls = 30, MusicGap = 12;

    /// The shape's spring (IslandRootView.morph) and the orb's flights (OrbFlightPlan).
    public const double MorphResponse = 0.36, MorphDamping = 0.84;
    public const double OrbOutResponse = 0.46, OrbOutDamping = 0.74;
    public const double OrbBackResponse = 0.32, OrbBackDamping = 0.92;

    public static double MusicHeight => TopInset + TabsHeight + Gap + MusicArtwork + MusicGap + MusicProgress + MusicGap + MusicControls + PadBottom;
    public static double VoiceHeight => TopInset + TabsHeight + Gap + VoicePanelHeight + PadBottom;

    /// The room a pane has under the tab row in an open island `height` tall.
    public static double PaneHeight(double height) => height - TopInset - TabsHeight - Gap - PadBottom;

    /// Measured: as tall as what the Agents tab holds (its header and cards, then the list with an
    /// opened session), up to MaxHeight; past that the list scrolls.
    public static double AgentsHeight(double top, double list) =>
        Math.Min(TopInset + TabsHeight + Gap + top + Gap + list + PadBottom, MaxHeight);

    /// Before the first layout: an estimate from what it will hold (the Mac's formula).
    public static double AgentsHeight(int sessions, PendingKind? pending, bool flash)
    {
        var h = TopInset + 34 + Gap + 40 + Gap + PadBottom;
        h += Math.Min(Math.Max(sessions, 1), 4) * RowHeight;
        h += pending switch { PendingKind.Question => 240, PendingKind.Approval => 160, _ => 0 };
        if (flash) h += 50;
        return Math.Min(h, MaxHeight);
    }

    public static double Height(IslandTab tab, int sessions, PendingKind? pending, bool flash) => tab switch
    {
        IslandTab.Agents => AgentsHeight(sessions, pending, flash),
        IslandTab.Chat => ChatHeight,
        IslandTab.Music => MusicHeight,
        _ => VoiceHeight,
    };

    /// The slim scroll bar's thumb: the visible share of the list, moving with the scroll. Null
    /// when everything fits.
    public static (double Start, double Length)? ScrollThumb(double content, double visible, double offset)
    {
        if (visible <= 0 || content <= visible + 1) return null;
        var length = Math.Max(24, visible * visible / content);
        var progress = Math.Clamp(offset / (content - visible), 0, 1);
        return ((visible - length) * progress, length);
    }

    /// The usage pill's colour: green under half, orange under 80%, red from there.
    public static string UsageColorKey(int? pct) => (pct ?? 0) switch
    {
        < 50 => "JcSysGreen",
        < 80 => "JcSysOrange",
        _ => "JcSysRed",
    };

    /// A limit bar's fill: the accent, amber from 75%, red from 90%.
    public static string LimitColorKey(int used) => used >= 90 ? "JcOrbRed" : used >= 75 ? "JcAmber" : "JcAccent";
}

/// When the compact tab stays up: while something needs you, while agents work only if he asked
/// for that, or always unless he turned on hiding when idle (the Mac's IslandVisibility).
public static class IslandVisibility
{
    public static bool KeepsTab(bool needsYou, bool working, bool showWhileWorking, bool hideWhenIdle) =>
        needsYou || (showWhileWorking && working) || !hideWhenIdle;
}

/// What keeps the open island from folding on its own: typing, a request waiting on him, or Voice.
public static class IslandPin
{
    public static bool Holds(bool typing, IslandTab tab, bool pending) => typing || pending || tab == IslandTab.Voice;
}
