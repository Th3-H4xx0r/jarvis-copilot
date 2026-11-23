using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Unlock;

/// Signing in from his iPhone at the sign-in screen after a restart (spec 2026-11-23-pc-boot-client §4). No Jarvis
/// app runs before he signs in, so jc-client's boot instance sends the request straight to the JarvisUnlock service,
/// which checks it itself (UnlockCheck, the app's own rule) and types ITS OWN copy of his password: the app's copy is
/// DPAPI under his account, which nothing can read before he signs in. The app keeps that copy in step when he saves
/// or clears his password, and hands it over once on start when the service has none. Pure logic, linked into the
/// helper (which gives it the file and the typist) and tested in Jarvis.Tests. Never logs the password.
///   `{"signin":{kind, context, nonce, proof:{ts, signature}, grant?, device}}` → the typist's reply (UnlockReply shape)
///   `{"store_password":"…"}` / `{"forget_password":true}` → `{"ok":true}`
///   `{"has_password":true}` → `{"ok":true,"has_password":…}`
public sealed class HelperSignIn
{
    public const string NoCopy = "Open Jarvis on the PC once and re-save your Windows password in Settings → PC power.";
    public const string NoKey = "Trust your iPhone in Jarvis Settings → PC power, then reinstall the helper.";
    public const string Unreadable = "The helper couldn't read its copy of your password. Open Jarvis on the PC and re-save your Windows password in Settings → PC power.";

    private readonly PasswordCopy _copy;
    private readonly Func<string?> _pinnedKey;
    private readonly UnlockApproval _approval;
    private readonly Func<string, string> _type;
    private readonly Action<string> _log;
    private readonly object _gate = new();   // one copy write / read at a time

    /// `pinnedKey`: the approval key pinned in Program Files at install (read each time, as admin_run does).
    /// `type`: types a password on the sign-in screen and answers in the UnlockReply shape.
    public HelperSignIn(PasswordCopy copy, Func<string?> pinnedKey, UnlockApproval approval, Func<string, string> type, Action<string>? log = null)
    {
        _copy = copy;
        _pinnedKey = pinnedKey;
        _approval = approval;
        _type = type;
        _log = log ?? (_ => { });
    }

    /// The reply to a sign-in or password-copy request; null when `request` is none of them (the service handles it).
    public string? Reply(JsonObject request, DateTimeOffset now)
    {
        if (request.ContainsKey("signin")) return SignIn(request["signin"] as JsonObject, now);
        if (request.ContainsKey("store_password")) return Store(J.StrOrNull(request["store_password"]));
        if (request.ContainsKey("forget_password")) return J.B(request["forget_password"]) ? Forget() : Error("Bad request.");
        if (request.ContainsKey("has_password")) return Ok(new JsonObject { ["has_password"] = Has() });
        return null;
    }

    /// The app's own fill (`{"password":…, "nonce":…}`, his Face ID yes checked by the app) spends that yes here
    /// too: the same yes can't come back as a sign-in.
    public void NoteAppFill(JsonObject request, DateTimeOffset now)
    {
        if (J.StrOrNull(request["nonce"]) is { Length: > 0 } nonce) _approval.Spend(nonce, now);
    }

    /// The app, on start (and after installing the helper), from the helper's answer to `{"has_password":true}`:
    /// hand its password over once when it has one and the helper has none; remove a copy left behind when he cleared
    /// his while the helper couldn't be reached. An older helper doesn't know the question (it answers an error), and
    /// no answer means leave it.
    public static CopyStep Sync(bool appHasPassword, JsonObject? hasReply)
    {
        if (hasReply is null || !IsJson(hasReply["ok"], JsonValueKind.True)) return CopyStep.Leave;
        if (appHasPassword && IsJson(hasReply["has_password"], JsonValueKind.False)) return CopyStep.HandOver;
        if (!appHasPassword && IsJson(hasReply["has_password"], JsonValueKind.True)) return CopyStep.Forget;
        return CopyStep.Leave;
    }

    private string SignIn(JsonObject? m, DateTimeOffset now)
    {
        if (m is null) return Error("Bad request.");
        if (UnlockCheck.Refusal(m, _pinnedKey(), _approval, now, NoKey) is { } why)
        {
            _log($"signin refused: {why}");
            return Error(why);
        }
        string? password;
        try
        {
            lock (_gate) password = _copy.Exists ? _copy.Read() : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException or DecoderFallbackException)
        {
            _log($"signin: couldn't read the password copy ({e.GetType().Name})");
            return Error(Unreadable);
        }
        if (string.IsNullOrEmpty(password))
        {
            _log("signin: no password copy");
            return Error(NoCopy);
        }
        _log(m["grant"] is JsonObject ? "signin: with his unlock permission" : "signin: with his Face ID yes");
        return _type(password);
    }

    private string Store(string? password)
    {
        if (string.IsNullOrEmpty(password)) return Error("No password was sent.");
        try
        {
            lock (_gate) _copy.Save(password);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            _log($"store_password failed ({e.GetType().Name})");
            return Error("The helper couldn't save its copy of your password.");
        }
        _log("store_password: saved the sign-in copy");
        return Ok();
    }

    private string Forget()
    {
        try
        {
            lock (_gate) _copy.Forget();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"forget_password failed ({e.GetType().Name})");
            return Error("The helper couldn't remove its copy of your password.");
        }
        _log("forget_password: removed the sign-in copy");
        return Ok();
    }

    private bool Has()
    {
        lock (_gate) return _copy.Exists;
    }

    private static bool IsJson(JsonNode? v, JsonValueKind kind) => v is JsonValue jv && jv.GetValueKind() == kind;

    private static string Ok(JsonObject? extra = null)
    {
        var o = extra ?? new JsonObject();
        o["ok"] = true;
        return o.ToJsonString();
    }

    private static string Error(string why) => new JsonObject { ["ok"] = false, ["error"] = why }.ToJsonString();
}

/// What the app does about the helper's copy on start (HelperSignIn.Sync).
public enum CopyStep { Leave, HandOver, Forget }

/// The JarvisUnlock service's own copy of his Windows password, for signing in before he has: one file, encrypted by
/// `protect` (on the PC: DPAPI LocalMachine, readable before anyone signs in) and written only through
/// `writeAdminOnly` (on the PC: next to the pinned approval key, an ACL only SYSTEM and Administrators can read).
public sealed class PasswordCopy
{
    public const string FileName = "signin-password.dat";

    private readonly Func<byte[], byte[]> _protect;
    private readonly Func<byte[], byte[]> _unprotect;
    private readonly Action<string, byte[]> _writeAdminOnly;

    public PasswordCopy(string path, Func<byte[], byte[]> protect, Func<byte[], byte[]> unprotect, Action<string, byte[]> writeAdminOnly)
    {
        Path = path;
        _protect = protect;
        _unprotect = unprotect;
        _writeAdminOnly = writeAdminOnly;
    }

    public string Path { get; }
    public bool Exists => File.Exists(Path);

    public void Save(string password)
    {
        if (password.Length == 0) throw new ArgumentException("empty password", nameof(password));
        _writeAdminOnly(Path, _protect(Encoding.UTF8.GetBytes(password)));
    }

    public string Read() =>
        new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(_unprotect(File.ReadAllBytes(Path)));

    public void Forget()
    {
        if (File.Exists(Path)) File.Delete(Path);
    }
}
