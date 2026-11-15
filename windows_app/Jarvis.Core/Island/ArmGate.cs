namespace Jarvis.Core.Island;

/// A card that just slid into place under the pointer ignores clicks briefly, so a double click
/// on the one before can't answer it unread.
public sealed record ArmGate(DateTimeOffset ShownAt)
{
    public static readonly TimeSpan Delay = TimeSpan.FromSeconds(0.5);
    public bool IsArmed(DateTimeOffset now) => now - ShownAt >= Delay;
}
