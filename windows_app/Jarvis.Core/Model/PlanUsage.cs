using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

/// One limit window: how much is used and when it resets (null when the server gave none).
public sealed record UsageWindow(int Used, DateTimeOffset? ResetsAt)
{
    /// What's used now: nothing once the window has reset.
    public int UsedNow(DateTimeOffset now) => ResetsAt is { } r && r <= now ? 0 : Used;
}

/// A plan's limits from the status line's `rate_limits` (port of MacPlanUsage).
public sealed record PlanUsage(UsageWindow? Five, UsageWindow? Week)
{
    /// `withRateLimits` is an object holding `rate_limits`.
    public static PlanUsage? FromJson(JsonObject withRateLimits)
    {
        var limits = J.Obj(withRateLimits["rate_limits"]);
        var five = Window(limits["five_hour"]);
        var week = Window(limits["seven_day"]);
        return five == null && week == null ? null : new PlanUsage(five, week);
    }

    private static UsageWindow? Window(JsonNode? w)
    {
        var o = J.Obj(w);
        if (J.D(o["used_percentage"]) is not { } used) return null;
        var reset = J.D(o["resets_at"]) ?? 0;
        return new UsageWindow((int)Math.Round(Math.Clamp(used, 0, 100), MidpointRounding.AwayFromZero),
            reset > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(reset * 1000)) : null);
    }
}

/// A limit window's pace (use minus the share of the window gone) and its countdown.
public static class UsagePace
{
    public static readonly TimeSpan FiveHours = TimeSpan.FromHours(5);
    public static readonly TimeSpan Week = TimeSpan.FromDays(7);

    public static double Pace(int used, DateTimeOffset resetsAt, TimeSpan length, DateTimeOffset now)
    {
        var left = Math.Min(Math.Max((resetsAt - now).TotalSeconds, 0), length.TotalSeconds);
        return used - (length.TotalSeconds - left) / length.TotalSeconds * 100;
    }

    public static string ResetsIn(DateTimeOffset resetsAt, DateTimeOffset now)
    {
        var s = (int)(resetsAt - now).TotalSeconds;
        if (s <= 0) return "now";
        int d = s / 86_400, h = s % 86_400 / 3600, m = s % 3600 / 60;
        if (d > 0) return $"{d} day{(d == 1 ? "" : "s")}" + (h > 0 ? $" {h}h" : "");
        if (h > 0) return $"{h}h {m}m";
        return $"{Math.Max(1, m)} min";
    }
}
