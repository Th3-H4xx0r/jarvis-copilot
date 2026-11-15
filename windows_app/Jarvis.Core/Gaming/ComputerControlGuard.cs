using Jarvis.Core.Model;

namespace Jarvis.Core.Gaming;

/// The refusal computer-control features return while a game is on (C3), or while an
/// anti-cheat game runs even in the background.
public static class ComputerControlGuard
{
    public static string? Refusal(GameMode m) =>
        m.On || m.AntiCheat
            ? $"Pranav is in a game ({m.Reason}); computer control is paused until he leaves it."
            : null;
}
