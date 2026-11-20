using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Unlock;
using Jarvis.Platform;
using Microsoft.Win32;

namespace Jarvis.Unlock;

/// Unlock PC from his iPhone (the Mac's "Unlock Mac"). jc-client asks his iPhone for Face ID and
/// broadcasts `password_fill` with the signed yes; this checks the signature against the iPhone
/// key pinned here, decrypts his Windows password (DPAPI, this Windows account only) and hands it
/// to the JarvisUnlock service, which types it on the lock screen only if it's showing and then
/// checks Windows really unlocked; anything less comes back as ok:false with why. Set up in
/// Settings → PC power: trust the iPhone's key, save the password, install the helper (Face ID +
/// UAC). The server never sees the password.
public sealed class PcUnlock
{
    private static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis");
    private static readonly string SecretPath = Path.Combine(Dir, "unlock.dat");
    private static readonly string KeyPath = Path.Combine(Dir, "approval-key.txt");
    public const string ApprovalKeyPath = "/api/coding/agents/mac/approval-key";

    private readonly IJcLink _link;
    private readonly ApiClient _api;
    private readonly AdminRunner _admin;
    private readonly UnlockApproval _approval = new();
    private readonly Action<string> _log = FileLog.For("unlock");

    public PcUnlock(IJcLink link, ApiClient api, AdminRunner admin)
    {
        _link = link;
        _api = api;
        _admin = admin;
        _link.Message += m => { if (J.S(m["type"]) == "password_fill") _ = FillAsync(m); };
    }

    public event Action? Changed;

    public bool HasPassword => File.Exists(SecretPath);
    public string? PinnedKey => File.Exists(KeyPath) ? File.ReadAllText(KeyPath).Trim() is { Length: > 0 } k ? k : null : null;
    public static bool HelperInstalled =>
        Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\JarvisUnlock") != null;

    // ── set-up ──────────────────────────────────────────────────────────

    /// His iPhone's approval key from the server: shown as its code before he trusts it.
    public async Task<string> FetchKeyAsync()
    {
        var reply = await _api.GetAsync(ApprovalKeyPath, TimeSpan.FromSeconds(10));
        return J.S(reply["public_key"]);
    }

    public void Pin(string publicKeyB64)
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(KeyPath, publicKeyB64);
        Changed?.Invoke();
    }

    public void SavePassword(string password)
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllBytes(SecretPath, Dpapi.Protect(Encoding.UTF8.GetBytes(password)));
        Changed?.Invoke();
    }

    public void ForgetPassword()
    {
        if (File.Exists(SecretPath)) File.Delete(SecretPath);
        Changed?.Invoke();
    }

    /// Face ID on his iPhone, then UAC: copies the helper to Program Files and starts the service.
    public async Task<AdminResult> InstallHelperAsync()
    {
        var exe = Path.Combine(AppContext.BaseDirectory, "JarvisUnlock.exe");
        if (!File.Exists(exe)) return new AdminResult(false, "failed", "The unlock helper is missing from this build.");
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        // The approval key goes to Program Files with it: the helper checks admin steps against that copy,
        // never this per-user one (anything running as him could rewrite it).
        var key = PinnedKey is { } k && AdminRun.ValidKey(k) ? " " + k : "";
        var result = await _admin.RunAsync($"\"{exe}\" --install {sid}{key}",
            "Install the helper that unlocks this PC and runs the admin steps you approve from your iPhone");
        // The elevated install finishes after UAC; look again shortly.
        _ = Task.Delay(TimeSpan.FromSeconds(8)).ContinueWith(_ => Changed?.Invoke());
        return result;
    }

    // ── the fill ────────────────────────────────────────────────────────

    private async Task FillAsync(JsonObject m)
    {
        var rid = J.S(m["id"]);
        string? error = null;
        try { error = await Task.Run(() => Fill(m)); }
        catch (Exception e) { error = "Unlock failed: " + e.Message; }
        _log($"fill {rid}: {error ?? "unlocked"}");
        var reply = new JsonObject { ["type"] = "password_fill_result", ["request_id"] = rid, ["ok"] = error == null };
        if (error != null) reply["error"] = error;
        await _link.RequestAsync(reply, TimeSpan.FromSeconds(10));
    }

    /// Null when the password was typed and Windows unlocked; otherwise why not.
    private string? Fill(JsonObject m)
    {
        if (J.S(m["kind"]) != "unlock") return "This PC only fills its lock screen.";
        if (PinnedKey is not { } key) return "Trust your iPhone in Jarvis Settings → PC power on the PC first.";
        var proof = m["proof"] as JsonObject;
        var ts = proof?["ts"] is JsonValue v && v.TryGetValue<double>(out var d) ? (long)d : 0;
        if (m["grant"] is JsonObject grant)
        {
            // His standing unlock permission instead of a fresh Face ID (UnlockGrant: signed, unexpired, this PC).
            if (UnlockGrant.Check(grant, J.S(m["device"]), key, DateTimeOffset.UtcNow) is { } why) return why;
        }
        else if (!_approval.Verify(J.S(m["context"]), "unlock", J.S(m["nonce"]), ts, J.S(proof?["signature"]), key, DateTimeOffset.UtcNow))
            return "Your iPhone's approval didn't check out on the PC.";
        if (!HasPassword) return "Save your Windows password in Jarvis Settings → PC power on the PC first.";
        if (!HelperInstalled) return "Install the unlock helper in Jarvis Settings → PC power on the PC first.";
        var password = Encoding.UTF8.GetString(Dpapi.Unprotect(File.ReadAllBytes(SecretPath)));
        try
        {
            using var pipe = new NamedPipeClientStream(".", "JarvisUnlock", PipeDirection.InOut);
            pipe.Connect(3000);
            var req = Encoding.UTF8.GetBytes(new JsonObject { ["password"] = password }.ToJsonString() + "\n");
            pipe.Write(req, 0, req.Length);
            pipe.Flush();
            using var reader = new StreamReader(pipe, Encoding.UTF8);
            var answer = J.Parse(reader.ReadLine() ?? "{}");
            return UnlockReply.Error(answer);
        }
        catch (TimeoutException) { return "The unlock helper isn't running. Reinstall it in Settings → PC power."; }
        catch (IOException e) { return "Couldn't reach the unlock helper: " + e.Message; }
        catch (UnauthorizedAccessException) { return "The unlock helper was installed for another Windows account."; }
    }
}

/// Windows' per-account encryption (CryptProtectData): only this Windows account on this PC can
/// read it back.
internal static partial class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int cbData; public IntPtr pbData; }

    public static byte[] Protect(byte[] data) => Run(data, protect: true);
    public static byte[] Unprotect(byte[] data) => Run(data, protect: false);

    private static byte[] Run(byte[] data, bool protect)
    {
        var input = new Blob { cbData = data.Length, pbData = Marshal.AllocHGlobal(Math.Max(1, data.Length)) };
        var output = new Blob();
        try
        {
            Marshal.Copy(data, 0, input.pbData, data.Length);
            var ok = protect
                ? CryptProtectData(ref input, "Jarvis unlock", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1 /* UI_FORBIDDEN */, ref output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, ref output);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.cbData];
            Marshal.Copy(output.pbData, result, 0, output.cbData);
            return result;
        }
        finally
        {
            Marshal.FreeHGlobal(input.pbData);
            if (output.pbData != IntPtr.Zero) LocalFree(output.pbData);
        }
    }

    [LibraryImport("crypt32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptProtectData(ref Blob data, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, ref Blob output);

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptUnprotectData(ref Blob data, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, ref Blob output);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr mem);
}
