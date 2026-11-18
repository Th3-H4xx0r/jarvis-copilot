using Jarvis.Core.Gaming;
using Jarvis.Core.Model;

namespace Jarvis.Core.Screen;

/// When a running (or waiting) share gives way to a game. jc-client's fullscreen check can flicker
/// (a system window in front for a moment), so a share ends only after "in a game" has held for
/// `Window` without a break. An anti-cheat game ends it at once: capture alone can upset anti-cheat.
/// Input is refused the whole time either way (ScreenShareService.TrySend), so nothing synthetic
/// reaches a game during the grace.
public sealed class ShareGameGrace
{
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(5);

    public abstract record Verdict;
    /// Not in a game.
    public sealed record Keep : Verdict;
    /// In a game for less than the grace: look again after `Left`.
    public sealed record Wait(TimeSpan Left) : Verdict;
    /// End it, saying why.
    public sealed record End(string Refusal) : Verdict;

    private DateTimeOffset? _since;

    public Verdict Observe(GameMode mode, DateTimeOffset now)
    {
        if (ComputerControlGuard.Refusal(mode) is not { } refusal)
        {
            _since = null;
            return new Keep();
        }
        _since ??= now;
        if (mode.AntiCheat) return new End(refusal);
        var left = Window - (now - _since.Value);
        return left <= TimeSpan.Zero ? new End(refusal) : new Wait(left);
    }
}

/// Whether this PC can capture its screen right now, and what to tell the phone when it can't.
/// After a Remote Desktop session ends, his session is left off the physical console (the console
/// shows the sign-in screen) and Windows refuses to capture until he signs back in.
public static class ShareReadiness
{
    public const string SignInScreen = "The PC is at the sign-in screen — unlock it first.";
    public const string RemoteDesktop = "Remote Desktop is in use on the PC.";
    public const string CaptureRefused = "Windows wouldn't let Jarvis capture the screen.";

    /// Null when a share can start.
    public static string? Refusal(bool onConsole, bool remoteSession) =>
        remoteSession ? RemoteDesktop : onConsole ? null : SignInScreen;

    /// Why starting capture threw (checked again at that moment).
    public static string CaptureFailure(bool onConsole, bool remoteSession) => Refusal(onConsole, remoteSession) ?? CaptureRefused;
}
