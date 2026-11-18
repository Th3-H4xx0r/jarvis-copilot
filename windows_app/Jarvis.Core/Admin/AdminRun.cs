using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Jarvis.Core.Unlock;

namespace Jarvis.Core.Admin;

/// One admin command for the IT agent (wire contract W4 in docs/superpowers/plans/2026-11-18-it-agent.md).
public sealed record AdminRunRequest(string Command, string Nonce, long Ts, string Signature, int TimeoutS);

/// The JarvisUnlock helper runs ONE admin command per Face ID approval from his iPhone: his P-256
/// signature over `jarvis-mac-password|admin-run|nonce|ts|sha256(command)` by the key pinned in
/// Program Files (admin-only; never the app's per-user copy, which his account can write), at most
/// 5 minutes old, each nonce once. The exact command he saw and signed is the only thing that runs.
/// Pure logic, linked into the helper and tested in Jarvis.Tests.
public static class AdminRun
{
    public const string Kind = "admin-run";
    public const int MaxCommandChars = 2400;
    public const int DefaultTimeoutS = 600;
    public const int MinTimeoutS = 10;
    public const int MaxTimeoutS = 1800;
    public const int MaxOutputChars = 16000;
    public const string KeyFileName = "approval-key.txt";

    /// The same prelude jc-client's pc_shell runs (W1): quiet progress, UTF-8 out, a fresh PATH.
    public const string Prelude =
        "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $env:WSL_UTF8='1'\n" +
        "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')";

    /// After the command (outside what his Face ID signs): exit with the command's own code — PowerShell
    /// -EncodedCommand otherwise ends 0/1, losing an installer's 3010 "restart required". Same as jc-client's.
    public const string ExitFooter =
        "$jcOk = $?; if (-not $jcOk) { if ($global:LASTEXITCODE) { exit $global:LASTEXITCODE } else { exit 1 } }; exit 0";

    /// The broker's nonce (secrets.token_hex(16)). Anything else is refused: a "|" in a nonce or kind could
    /// shift the signed fields (`…|admin-run|x|y|…`) and pass a disguised approval off as this kind.
    private static readonly Regex NonceShape = new("^[0-9a-f]{32}$");

    private static readonly Regex ClixmlError = new("<S S=\"Error\">(.*?)</S>", RegexOptions.Singleline);
    private static readonly Regex XmlEscape = new("_x([0-9A-Fa-f]{4})_");

    public static AdminRunRequest? Parse(JsonNode? node, out string error)
    {
        error = "";
        if (node is not JsonObject o)
        {
            error = "Bad request.";
            return null;
        }
        string S(string k) => o[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
        long L(string k) => o[k] is JsonValue v ? (v.TryGetValue<long>(out var l) ? l : v.TryGetValue<double>(out var d) ? (long)d : 0) : 0;
        var command = S("command");
        var nonce = S("nonce");
        var signature = S("signature");
        var ts = L("ts");
        if (command.Length == 0 || nonce.Length == 0 || signature.Length == 0 || ts == 0)
        {
            error = "Bad request.";
            return null;
        }
        var timeout = o["timeout_s"] is null ? DefaultTimeoutS : (int)Math.Clamp(L("timeout_s"), MinTimeoutS, MaxTimeoutS);
        return new AdminRunRequest(command, nonce, ts, signature, Math.Clamp(timeout, MinTimeoutS, MaxTimeoutS));
    }

    /// Null when it may run; otherwise why not (shown on his phone's job card).
    public static string? Refusal(AdminRunRequest r, string? pinnedKey, UnlockApproval approval, DateTimeOffset now)
    {
        if (!ValidKey(pinnedKey)) return "Trust your iPhone in Jarvis Settings → PC power, then reinstall the helper.";
        if (r.Command.Length > MaxCommandChars) return "The command is too long to sign.";
        if (!NonceShape.IsMatch(r.Nonce)) return "Your iPhone's approval didn't check out on the PC.";
        return approval.Verify(r.Command, Kind, r.Nonce, r.Ts, r.Signature, pinnedKey!, now)
            ? null
            : "Your iPhone's approval didn't check out on the PC.";
    }

    public static string EncodedCommand(string command) =>
        Convert.ToBase64String(Encoding.Unicode.GetBytes(Prelude + "\n" + command + "\n" + ExitFooter));

    /// stdout then stderr (each cleaned, errors as text), the tail kept when it's long.
    public static (string Output, bool Truncated) Cap(string stdout, string stderr)
    {
        stdout = Clean(stdout);
        stderr = PlainErrors(Clean(stderr));
        var both = stdout.Length > 0 && stderr.Length > 0 ? stdout + "\n" + stderr : stdout + stderr;
        return both.Length > MaxOutputChars ? (both[^MaxOutputChars..], true) : (both, false);
    }

    /// UTF-16 text read as UTF-8 (wsl.exe writes UTF-16LE whatever the console says, live): a quarter or
    /// more NUL characters means that, so drop them. Line ends fold to "\n".
    public static string Clean(string s)
    {
        if (s.Length > 0 && s.Count(c => c == '\0') * 4 >= s.Length) s = s.Replace("\0", "");
        return s.Replace("\r\r\n", "\n").Replace("\r\n", "\n");
    }

    /// PowerShell writes errors as CLIXML when stderr is redirected: keep only their text.
    public static string PlainErrors(string stderr)
    {
        // A tool's own stderr (wsl.exe's) can come first: find the block wherever it starts (live).
        var at = stderr.IndexOf("#< CLIXML", StringComparison.Ordinal);
        if (at < 0) return stderr;
        var parts = ClixmlError.Matches(stderr[at..]).Select(m => m.Groups[1].Value).ToList();
        if (parts.Count == 0) return stderr;
        var text = string.Concat(parts.Select(p => WebUtility.HtmlDecode(
            XmlEscape.Replace(p, m => ((char)Convert.ToInt32(m.Groups[1].Value, 16)).ToString()))))
            .Replace("\r\n", "\n").TrimEnd('\n');
        var head = stderr[..at].TrimEnd('\n', '\r');
        return head.Trim().Length > 0 ? head + "\n" + text : text;
    }

    /// Which session an admin command runs in: his, never anyone else's — the console when it's his, else his
    /// active session (signed in over Remote Desktop, live 2026-11-18), else any of his. Null: he isn't signed in.
    /// `sessions`: (id, WTS state (0 = active), the session user's SID or null).
    public static uint? PickSession(IEnumerable<(uint Id, int State, string? Sid)> sessions, uint console, string sid)
    {
        var his = sessions.Where(s => string.Equals(s.Sid, sid, StringComparison.OrdinalIgnoreCase)).ToList();
        if (his.Count == 0) return null;
        if (his.Any(s => s.Id == console)) return console;
        return his.Where(s => s.State == 0).Select(s => (uint?)s.Id).FirstOrDefault() ?? his[0].Id;
    }

    /// The service's DACL with an ACE letting his account start/stop/query it (so jc-client can bring a
    /// stopped helper back without UAC). Null when it already has one or the SDDL can't be read.
    public static string? GrantStart(string sddl, string sid)
    {
        var s = sddl.Trim();
        if (!s.StartsWith("D:", StringComparison.Ordinal) || s.Contains(";;;" + sid + ")", StringComparison.OrdinalIgnoreCase)) return null;
        var ace = $"(A;;RPWPLCRC;;;{sid})";
        var sacl = s.IndexOf("S:", StringComparison.Ordinal);
        return sacl < 0 ? s + ace : s[..sacl] + ace + s[sacl..];
    }

    /// A pinned key: the iPhone's x9.63 P-256 point (04 ‖ X ‖ Y, 65 bytes).
    public static bool ValidKey(string? b64)
    {
        if (string.IsNullOrEmpty(b64)) return false;
        try
        {
            var point = Convert.FromBase64String(b64);
            return point.Length == 65 && point[0] == 0x04;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public static string Reply(int? exit, string output, bool truncated, bool timedOut, long ms) => new JsonObject
    {
        ["ok"] = true,
        ["exit_code"] = exit is { } e ? JsonValue.Create(e) : null,
        ["output"] = output,
        ["truncated"] = truncated,
        ["timed_out"] = timedOut,
        ["duration_ms"] = ms,
    }.ToJsonString();
}
