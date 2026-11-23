using System.Security.Cryptography;
using System.Text;
using Jarvis.Core.Unlock;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Unlock;

/// Signing in from his iPhone at the sign-in screen after a restart (spec 2026-11-23-pc-boot-client §4): no Jarvis
/// app runs yet, so the JarvisUnlock service checks his yes itself (the app's own rule, UnlockCheck) and types its
/// own copy of his password, which the app gives it when he saves or clears his.
public class HelperSignInTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private const string Device = "pc-1";
    private const string Password = "correct horse ✓";
    private const string Checked = "{\"ok\":true,\"checked\":true}";

    private static (string Pub, Func<byte[], string> Sign) Phone()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var pub = Convert.ToBase64String(new byte[] { 0x04 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray());
        return (pub, m => Convert.ToBase64String(key.SignData(m, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    /// The service with a temp folder for its copy, a fake "encryption" (so the file never holds the plain text) and
    /// a typist that records what it was given.
    private sealed class Rig
    {
        public readonly List<string> Typed = new();
        public readonly List<string> Log = new();
        public readonly List<string> AdminOnlyWrites = new();
        public readonly UnlockApproval Approval = new();
        public readonly PasswordCopy Copy;
        public readonly HelperSignIn Helper;
        public string? Key;

        public Rig(string? key)
        {
            Key = key;
            Copy = new PasswordCopy(Path.Combine(Tmp.Dir(), PasswordCopy.FileName), Scramble, Scramble,
                (path, bytes) => { AdminOnlyWrites.Add(path); File.WriteAllBytes(path, bytes); });
            Helper = new HelperSignIn(Copy, () => Key, Approval, pw => { Typed.Add(pw); return Checked; }, Log.Add);
        }

        public JsonObject Ask(string json, DateTimeOffset? at = null)
        {
            var reply = Helper.Reply(JsonNode.Parse(json)!.AsObject(), at ?? Now);
            Assert.NotNull(reply);
            return JsonNode.Parse(reply!)!.AsObject();
        }

        public void Stored() => Assert.True(Ok(Ask(new JsonObject { ["store_password"] = Password }.ToJsonString())));
    }

    private static byte[] Scramble(byte[] b) => b.Select(x => (byte)(x ^ 0x5A)).ToArray();

    private static bool Ok(JsonObject r) => r["ok"] is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.True;
    private static string Err(JsonObject r) => r["error"]?.GetValue<string>() ?? "";

    /// What jc-client's boot instance sends: {"signin": {kind, context, nonce, proof:{ts, signature}, device}}.
    private static string FaceIdSignIn(Func<byte[], string> sign, string nonce = "0123456789abcdef0123456789abcdef",
                                       string kind = "unlock", string context = "Unlock PC", string? signedContext = null,
                                       long? ts = null)
    {
        var t = ts ?? Now.ToUnixTimeSeconds();
        var sig = sign(UnlockApproval.Message("unlock", nonce, t, signedContext ?? context));
        return new JsonObject
        {
            ["signin"] = new JsonObject
            {
                ["kind"] = kind, ["context"] = context, ["nonce"] = nonce, ["device"] = Device,
                ["proof"] = new JsonObject { ["ts"] = t, ["signature"] = sig },
            },
        }.ToJsonString();
    }

    /// The same with his unlock permission instead of a fresh Face ID yes.
    private static string GrantSignIn(Func<byte[], string> sign, string grantDevice = Device, string device = Device)
    {
        const string id = "abababababababababababababababab";
        var t = Now.ToUnixTimeSeconds();
        var until = t + 3600;
        var sig = sign(UnlockApproval.Message(UnlockGrant.Kind, id, t, UnlockGrant.Context(grantDevice, until)));
        return new JsonObject
        {
            ["signin"] = new JsonObject
            {
                ["kind"] = "unlock", ["context"] = "Unlock PC", ["nonce"] = "fedcba9876543210fedcba9876543210", ["device"] = device,
                ["grant"] = new JsonObject { ["id"] = id, ["ts"] = t, ["until"] = until, ["device"] = grantDevice, ["signature"] = sig },
            },
        }.ToJsonString();
    }

    // ── signing in ──────────────────────────────────────────────────────

    [Fact]
    public void SignIn_WithHisFaceIdYes_TypesTheServicesOwnCopy()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        var reply = rig.Ask(FaceIdSignIn(sign));
        Assert.True(Ok(reply));
        Assert.True(reply["checked"]!.GetValue<bool>());   // the typist's own reply: the existing UnlockReply shape
        Assert.Null(UnlockReply.Error(reply));
        Assert.Equal(new[] { Password }, rig.Typed);
    }

    [Fact]
    public void SignIn_Forged_IsRefused_AndNothingIsTyped()
    {
        var (pub, sign) = Phone();
        var (_, otherSign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(FaceIdSignIn(otherSign))));   // another key signed it
        var forged = JsonNode.Parse(FaceIdSignIn(sign, nonce: "11111111111111111111111111111111"))!.AsObject();
        forged["signin"]!["proof"]!["signature"] = Convert.ToBase64String(new byte[70]);
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(forged.ToJsonString())));
        var noProof = JsonNode.Parse(FaceIdSignIn(sign, nonce: "44444444444444444444444444444444"))!.AsObject();
        noProof["signin"]!.AsObject().Remove("proof");
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(noProof.ToJsonString())));
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_TamperedOrStaleOrNotAnUnlock_IsRefused()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        // he approved other text than what's sent
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(FaceIdSignIn(sign, context: "Unlock PC", signedContext: "Run something"))));
        // older than 5 minutes
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(FaceIdSignIn(sign, nonce: "22222222222222222222222222222222"), Now.AddMinutes(6))));
        // a sudo / admin yes is never a sign-in
        Assert.Equal(UnlockCheck.NotUnlock, Err(rig.Ask(FaceIdSignIn(sign, nonce: "33333333333333333333333333333333", kind: "sudo"))));
        Assert.Equal("Bad request.", Err(rig.Ask("{\"signin\":\"unlock\"}")));
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_Replayed_IsRefused()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        var once = FaceIdSignIn(sign);
        Assert.True(Ok(rig.Ask(once)));
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(once)));
        Assert.Single(rig.Typed);
    }

    [Fact]
    public void SignIn_WithAYesTheAppAlreadyFilled_IsRefused()
    {
        // The app's own fill ({"password":…, "nonce":…}) spends its yes here too: the server can't send the same
        // yes again as a sign-in.
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        rig.Helper.NoteAppFill(JsonNode.Parse("{\"password\":\"x\",\"nonce\":\"0123456789abcdef0123456789abcdef\"}")!.AsObject(), Now);
        Assert.Equal(UnlockCheck.BadApproval, Err(rig.Ask(FaceIdSignIn(sign))));
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_WithHisUnlockPermission_TypesWithoutFaceId()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        Assert.True(Ok(rig.Ask(GrantSignIn(sign))));
        Assert.Equal(new[] { Password }, rig.Typed);
    }

    [Fact]
    public void SignIn_PermissionForAnotherComputer_IsRefused()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        Assert.Contains("another computer", Err(rig.Ask(GrantSignIn(sign, grantDevice: "mac-1", device: Device))));
        Assert.Contains("another computer", Err(rig.Ask(GrantSignIn(sign, grantDevice: Device, device: "mac-1"))));
        var (_, otherSign) = Phone();
        Assert.Contains("didn't check out", Err(rig.Ask(GrantSignIn(otherSign))));
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_WithoutTheServicesCopy_SaysHowToMakeIt()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        var reply = rig.Ask(FaceIdSignIn(sign));
        Assert.False(Ok(reply));
        Assert.Equal("Open Jarvis on the PC once and re-save your Windows password in Settings → PC power.", Err(reply));
        Assert.Equal(HelperSignIn.NoCopy, Err(reply));
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_WithoutAPinnedKey_SaysReinstallTheHelper()
    {
        var (_, sign) = Phone();
        var rig = new Rig(null);
        rig.Stored();
        Assert.Equal(HelperSignIn.NoKey, Err(rig.Ask(FaceIdSignIn(sign))));
        Assert.Contains("reinstall the helper", HelperSignIn.NoKey);
        Assert.Empty(rig.Typed);
    }

    [Fact]
    public void SignIn_UnreadableCopy_SaysResave_NeverTypes()
    {
        var (pub, sign) = Phone();
        var dir = Tmp.Dir();
        var copy = new PasswordCopy(Path.Combine(dir, PasswordCopy.FileName), b => b,
            _ => throw new CryptographicException("key gone"), (p, b) => File.WriteAllBytes(p, b));
        var typed = new List<string>();
        var helper = new HelperSignIn(copy, () => pub, new UnlockApproval(), pw => { typed.Add(pw); return Checked; });
        copy.Save(Password);
        var reply = JsonNode.Parse(helper.Reply(JsonNode.Parse(FaceIdSignIn(sign))!.AsObject(), Now)!)!.AsObject();
        Assert.Contains("re-save your Windows password", Err(reply));
        Assert.Empty(typed);
    }

    [Fact]
    public void ThePassword_IsNeverLogged()
    {
        var (pub, sign) = Phone();
        var rig = new Rig(pub);
        rig.Stored();
        rig.Ask(FaceIdSignIn(sign));
        rig.Ask(FaceIdSignIn(sign));
        rig.Ask("{\"forget_password\":true}");
        Assert.NotEmpty(rig.Log);
        Assert.DoesNotContain(rig.Log, l => l.Contains(Password, StringComparison.Ordinal) || l.Contains("horse", StringComparison.Ordinal));
    }

    // ── the service's copy ──────────────────────────────────────────────

    [Fact]
    public void StorePassword_WritesTheAdminOnlyFile_Encrypted()
    {
        var rig = new Rig("k");
        Assert.False(rig.Copy.Exists);
        rig.Stored();
        Assert.True(File.Exists(rig.Copy.Path));
        Assert.Equal(new[] { rig.Copy.Path }, rig.AdminOnlyWrites);   // only through the admin-only writer
        var onDisk = File.ReadAllBytes(rig.Copy.Path);
        Assert.NotEqual(Encoding.UTF8.GetBytes(Password), onDisk);
        Assert.Equal(Password, rig.Copy.Read());
        Assert.True(rig.Ask("{\"has_password\":true}")["has_password"]!.GetValue<bool>());
    }

    [Fact]
    public void StorePassword_Again_ReplacesIt()
    {
        var rig = new Rig("k");
        rig.Stored();
        Assert.True(Ok(rig.Ask("{\"store_password\":\"new pin 1234\"}")));
        Assert.Equal("new pin 1234", rig.Copy.Read());
    }

    [Fact]
    public void StorePassword_EmptyOrNotText_IsRefused_AndKeepsTheOldCopy()
    {
        var rig = new Rig("k");
        rig.Stored();
        Assert.False(Ok(rig.Ask("{\"store_password\":\"\"}")));
        Assert.False(Ok(rig.Ask("{\"store_password\":42}")));
        Assert.Equal(Password, rig.Copy.Read());
    }

    [Fact]
    public void ForgetPassword_DeletesTheFile()
    {
        var rig = new Rig("k");
        rig.Stored();
        Assert.True(Ok(rig.Ask("{\"forget_password\":true}")));
        Assert.False(File.Exists(rig.Copy.Path));
        Assert.False(rig.Ask("{\"has_password\":true}")["has_password"]!.GetValue<bool>());
        Assert.True(Ok(rig.Ask("{\"forget_password\":true}")));   // nothing there: still fine
    }

    [Fact]
    public void OtherRequests_AreLeftToTheService()
    {
        var rig = new Rig("k");
        foreach (var other in new[] { "{\"password\":\"x\"}", "{\"rdp\":\"on\"}", "{\"admin_run\":{}}", "{}" })
            Assert.Null(rig.Helper.Reply(JsonNode.Parse(other)!.AsObject(), Now));
    }

    // ── the app's side ──────────────────────────────────────────────────

    [Fact]
    public void App_HandsItsPasswordOver_OnlyWhenTheHelperSaysItHasNone()
    {
        JsonObject R(string s) => JsonNode.Parse(s)!.AsObject();
        Assert.Equal(CopyStep.HandOver, HelperSignIn.Sync(true, R("{\"ok\":true,\"has_password\":false}")));
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(true, R("{\"ok\":true,\"has_password\":true}")));
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(false, R("{\"ok\":true,\"has_password\":false}")));
        // an older helper doesn't know the question (it answers "No password was sent."), or no answer at all
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(true, R("{\"ok\":false,\"error\":\"No password was sent.\"}")));
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(false, R("{\"ok\":false,\"error\":\"No password was sent.\"}")));
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(true, null));
        Assert.Equal(CopyStep.Leave, HelperSignIn.Sync(true, R("{\"ok\":true,\"has_password\":\"false\"}")));
    }

    [Fact]
    public void App_RemovesACopyLeftBehind_WhenHeClearedHisPassword()
    {
        // He pressed Forget while the helper couldn't be reached: the next start removes the helper's copy.
        Assert.Equal(CopyStep.Forget, HelperSignIn.Sync(false, JsonNode.Parse("{\"ok\":true,\"has_password\":true}")!.AsObject()));
    }

    // ── the one rule the app and the service share ──────────────────────

    [Fact]
    public void UnlockCheck_IsTheAppsFillRule()
    {
        var (pub, sign) = Phone();
        JsonObject M(string s) => JsonNode.Parse(s)!["signin"]!.AsObject();
        var approval = new UnlockApproval();
        Assert.Equal(UnlockCheck.NotUnlock, UnlockCheck.Refusal(M(FaceIdSignIn(sign, kind: "sudo")), pub, approval, Now));
        Assert.Equal(UnlockCheck.NoKey, UnlockCheck.Refusal(M(FaceIdSignIn(sign)), null, approval, Now));
        Assert.Equal(UnlockCheck.NoKey, UnlockCheck.Refusal(M(FaceIdSignIn(sign)), " ", approval, Now));
        Assert.Null(UnlockCheck.Refusal(M(FaceIdSignIn(sign)), pub, approval, Now));
        Assert.Equal(UnlockCheck.BadApproval, UnlockCheck.Refusal(M(FaceIdSignIn(sign)), pub, approval, Now));   // once
        Assert.Null(UnlockCheck.Refusal(M(GrantSignIn(sign)), pub, approval, Now));
        Assert.Null(UnlockCheck.Refusal(M(GrantSignIn(sign)), pub, approval, Now));   // a permission stands
    }
}
