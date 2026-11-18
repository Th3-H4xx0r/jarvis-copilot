using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Unlock;

/// The JarvisUnlock helper's pipe reply, as the app reads it. Only `{"ok":true,"checked":true}`
/// (typed, and Windows unlocked) counts: an older helper answered `{"ok":true}` the moment it pressed
/// Enter, without checking, which is how a "please enter your PIN" box could still read as unlocked.
public static class UnlockReply
{
    public const string OldHelper =
        "The unlock helper is out of date and can't tell whether Windows unlocked. Reinstall it in Jarvis Settings → PC power on the PC.";

    /// Null when the PC unlocked; otherwise why not.
    public static string? Error(JsonObject reply)
    {
        if (IsTrue(reply["ok"])) return IsTrue(reply["checked"]) ? null : OldHelper;
        return J.S(reply["error"]) is { Length: > 0 } e ? e : "The unlock helper didn't type it.";
    }

    private static bool IsTrue(JsonNode? v) => v is JsonValue jv && jv.GetValueKind() == JsonValueKind.True;
}
