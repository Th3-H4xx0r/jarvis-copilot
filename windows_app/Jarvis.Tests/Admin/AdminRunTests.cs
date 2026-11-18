using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Admin;

/// The helper runs one admin command only when his iPhone's Face ID signature covers exactly that
/// command (kind admin-run), fresh and once, against the key pinned in Program Files (W4).
public class AdminRunTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static (string Pub, Func<byte[], string> Sign) Phone()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var pub = Convert.ToBase64String(new byte[] { 0x04 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray());
        return (pub, m => Convert.ToBase64String(key.SignData(m, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    private static string Hex(char c) => new(c, 32);   // the broker's nonce: 32 lowercase hex

    private static AdminRunRequest Signed(Func<byte[], string> sign, string signedCommand, string command, string? nonce = null,
                                          string kind = AdminRun.Kind, long? ts = null)
    {
        var t = ts ?? Now.ToUnixTimeSeconds();
        var n = nonce ?? Hex('1');
        return new AdminRunRequest(command, n, t, sign(UnlockApproval.Message(kind, n, t, signedCommand)), 600);
    }

    [Fact]
    public void Parse_ReadsFields_ClampsTimeout()
    {
        JsonNode Node(string timeout) => JsonNode.Parse(
            $"{{\"command\":\"wsl --install\",\"nonce\":\"n1\",\"ts\":1800000000,\"signature\":\"c2ln\"{timeout}}}")!;
        var r = AdminRun.Parse(Node(",\"timeout_s\":900"), out var error);
        Assert.Equal(new AdminRunRequest("wsl --install", "n1", 1_800_000_000, "c2ln", 900), r);
        Assert.Equal("", error);
        Assert.Equal(10, AdminRun.Parse(Node(",\"timeout_s\":5"), out _)!.TimeoutS);
        Assert.Equal(1800, AdminRun.Parse(Node(",\"timeout_s\":99999"), out _)!.TimeoutS);
        Assert.Equal(600, AdminRun.Parse(Node(""), out _)!.TimeoutS);
    }

    [Fact]
    public void Parse_RefusesMissingFields()
    {
        Assert.Null(AdminRun.Parse(JsonNode.Parse("{\"nonce\":\"n1\",\"ts\":1,\"signature\":\"s\"}"), out var e1));
        Assert.Null(AdminRun.Parse(JsonNode.Parse("{\"command\":\"x\",\"ts\":1,\"signature\":\"s\"}"), out _));
        Assert.Null(AdminRun.Parse(JsonNode.Parse("{\"command\":\"x\",\"nonce\":\"n\",\"signature\":\"s\"}"), out _));
        Assert.Null(AdminRun.Parse(JsonNode.Parse("{\"command\":\"x\",\"nonce\":\"n\",\"ts\":1}"), out _));
        Assert.Null(AdminRun.Parse(null, out _));
        Assert.Equal("Bad request.", e1);
    }

    [Fact]
    public void Refusal_NullForHisSignatureOverExactCommand_Once()
    {
        var (pub, sign) = Phone();
        var approval = new UnlockApproval();
        var r = Signed(sign, "wsl --install --no-distribution", "wsl --install --no-distribution");
        Assert.Null(AdminRun.Refusal(r, pub, approval, Now));
        Assert.Equal("Your iPhone's approval didn't check out on the PC.", AdminRun.Refusal(r, pub, approval, Now));
    }

    [Fact]
    public void Refusal_OtherCommandKindKeyOrStale()
    {
        var (pub, sign) = Phone();
        var (otherPub, _) = Phone();
        const string No = "Your iPhone's approval didn't check out on the PC.";
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir ", Hex('a')), pub, new UnlockApproval(), Now));
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir", Hex('b'), kind: "unlock"), pub, new UnlockApproval(), Now));
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir", Hex('c')), otherPub, new UnlockApproval(), Now));
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir", Hex('d')), pub, new UnlockApproval(), Now.AddMinutes(6)));
    }

    [Fact]
    public void Refusal_NonceMustBeTheBrokersHex()
    {
        // A server that sent the phone kind "admin-run|x" and nonce "y" gets a signature over
        // "…|admin-run|x|y|…": replayed here with nonce "x|y" it must not check out (bug sweep B2).
        var (pub, sign) = Phone();
        const string No = "Your iPhone's approval didn't check out on the PC.";
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir", "x|y"), pub, new UnlockApproval(), Now));
        Assert.Equal(No, AdminRun.Refusal(Signed(sign, "dir", "dir", new string('A', 32)), pub, new UnlockApproval(), Now));
        Assert.Null(AdminRun.Refusal(Signed(sign, "dir", "dir", Hex('e')), pub, new UnlockApproval(), Now));
    }

    [Fact]
    public void Refusal_NoPinnedKey()
    {
        var (_, sign) = Phone();
        var r = Signed(sign, "dir", "dir");
        const string Trust = "Trust your iPhone in Jarvis Settings → PC power, then reinstall the helper.";
        Assert.Equal(Trust, AdminRun.Refusal(r, null, new UnlockApproval(), Now));
        Assert.Equal(Trust, AdminRun.Refusal(r, "not a key", new UnlockApproval(), Now));
    }

    [Fact]
    public void Refusal_TooLong()
    {
        var (pub, sign) = Phone();
        var cmd = new string('x', 2401);
        Assert.Equal("The command is too long to sign.", AdminRun.Refusal(Signed(sign, cmd, cmd), pub, new UnlockApproval(), Now));
    }

    [Fact]
    public void EncodedCommand_HasPreludeThenCommand()
    {
        var decoded = Encoding.Unicode.GetString(Convert.FromBase64String(AdminRun.EncodedCommand("wsl --status")));
        Assert.StartsWith("$ProgressPreference='SilentlyContinue'", decoded);
        Assert.Equal(AdminRun.Prelude + "\nwsl --status\n" + AdminRun.ExitFooter, decoded);
        Assert.Equal("$jcOk = $?; if (-not $jcOk) { if ($global:LASTEXITCODE) { exit $global:LASTEXITCODE } else { exit 1 } }; exit 0",
                     AdminRun.ExitFooter);
        Assert.Equal("$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $env:WSL_UTF8='1'\n" +
                     "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')",
                     AdminRun.Prelude);
    }

    [Fact]
    public void Cap_KeepsTail()
    {
        var big = new string('a', 19_999) + "z";
        var (output, truncated) = AdminRun.Cap(big, "");
        Assert.Equal(16_000, output.Length);
        Assert.True(truncated);
        Assert.EndsWith("z", output);
        Assert.Equal(("out\nerr", false), AdminRun.Cap("out", "err"));
        Assert.Equal(("err", false), AdminRun.Cap("", "err"));
    }

    [Fact]
    public void Cap_ReadsUtf16TextFromWsl()
    {
        // wsl.exe writes UTF-16LE while WSL isn't installed; read as UTF-8 every other char is a NUL (live).
        var asRead = new string("The Windows Subsystem for Linux is not installed.\r\r\n".SelectMany(c => new[] { c, '\0' }).ToArray());
        Assert.Equal(("The Windows Subsystem for Linux is not installed.\n", false), AdminRun.Cap(asRead, ""));
        Assert.Equal(("ok\nwsl: no", false), AdminRun.Cap("ok", new string("wsl: no".SelectMany(c => new[] { c, '\0' }).ToArray())));
    }

    [Fact]
    public void PlainErrors_ReadsClixmlAsText()
    {
        var clixml = "#< CLIXML\r\n<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\">" +
                     "<S S=\"Error\">dism : Error 87_x000D__x000A_</S><S S=\"Error\">The option &apos;x&apos; is unknown._x000D__x000A_</S></Objs>";
        Assert.Equal("dism : Error 87\nThe option 'x' is unknown.", AdminRun.PlainErrors(clixml));
        Assert.Equal("plain error", AdminRun.PlainErrors("plain error"));
    }

    [Fact]
    public void PlainErrors_ClixmlAfterAToolsOwnText()
    {
        var err = "The Windows Subsystem for Linux is not installed.\n#< CLIXML\r\n<Objs Version=\"1.1.0.1\" " +
                  "xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><S S=\"Error\">Get-Thing : bad_x000D__x000A_</S></Objs>";
        Assert.Equal("The Windows Subsystem for Linux is not installed.\nGet-Thing : bad", AdminRun.PlainErrors(err));
    }

    [Fact]
    public void GrantStart_AddsHisAceBeforeTheSacl_Once()
    {
        const string Sid = "S-1-5-21-1-2-3-1001";
        var sddl = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCLCSWLOCRRC;;;IU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)";
        var granted = AdminRun.GrantStart(sddl, Sid)!;
        Assert.Equal("D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCLCSWLOCRRC;;;IU)(A;;RPWPLCRC;;;S-1-5-21-1-2-3-1001)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)", granted);
        Assert.Null(AdminRun.GrantStart(granted, Sid));
        Assert.Equal("D:(A;;LC;;;SY)(A;;RPWPLCRC;;;" + Sid + ")", AdminRun.GrantStart("D:(A;;LC;;;SY)", Sid));
        Assert.Null(AdminRun.GrantStart("garbage", Sid));
    }

    [Fact]
    public void ValidKey_AcceptsOnlyUncompressedP256Points()
    {
        var (pub, _) = Phone();
        Assert.True(AdminRun.ValidKey(pub));
        var compressed = Convert.ToBase64String(new byte[] { 0x02 }.Concat(new byte[32]).ToArray());
        Assert.False(AdminRun.ValidKey(compressed));
        Assert.False(AdminRun.ValidKey(Convert.ToBase64String(new byte[] { 0x04 }.Concat(new byte[63]).ToArray())));
        Assert.False(AdminRun.ValidKey("%%%"));
        Assert.False(AdminRun.ValidKey(null));
        Assert.False(AdminRun.ValidKey(""));
    }

    [Fact]
    public void Reply_IsTheWireShape()
    {
        var done = JsonNode.Parse(AdminRun.Reply(0, "done", false, false, 12))!;
        Assert.True(done["ok"]!.GetValue<bool>());
        Assert.Equal(0, done["exit_code"]!.GetValue<int>());
        Assert.Equal("done", done["output"]!.GetValue<string>());
        Assert.Equal(12, done["duration_ms"]!.GetValue<long>());
        var hung = JsonNode.Parse(AdminRun.Reply(null, "", true, true, 5))!;
        Assert.Null(hung["exit_code"]);
        Assert.True(hung["timed_out"]!.GetValue<bool>() && hung["truncated"]!.GetValue<bool>());
    }
}
