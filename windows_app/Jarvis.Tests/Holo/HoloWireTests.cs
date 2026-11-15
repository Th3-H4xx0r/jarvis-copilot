using System.Text;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Core.Link;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Holo;

public class HoloWireTests
{
    [Fact]
    public void UploadPath_EncodesPlus() => Assert.Equal(
        "/api/holo-drop/drops/upload?kind=file&target=d1&name=a%2Bb.txt&mime=text%2Fplain&action=save&x=0.5&y=0.25",
        HoloWire.UploadPath(HoloKind.File, "d1", "a+b.txt", "text/plain", HoloAction.Save, new HoloPosition(0.5, 0.25)));

    [Fact]
    public void Fraction_TrimsZeros()
    {
        Assert.Equal("0.5", HoloWire.Fraction(0.5));
        Assert.Equal("0", HoloWire.Fraction(0));
        Assert.Equal("0.3333", HoloWire.Fraction(1.0 / 3));
        Assert.Equal("1", HoloWire.Fraction(1));
    }

    [Fact]
    public void Outcome_FromSteps()
    {
        Assert.Equal(HoloOutcome.SavedOpened, HoloOutcome.From(saved: true, opened: true, copied: false, shown: false));
        Assert.Equal(HoloOutcome.SavedCopied, HoloOutcome.From(saved: true, opened: false, copied: true, shown: false));
        Assert.Equal(HoloOutcome.Copied, HoloOutcome.From(saved: false, opened: false, copied: true, shown: true));
        Assert.Equal(HoloOutcome.Shown, HoloOutcome.From(saved: false, opened: false, copied: false, shown: true));
        Assert.Equal(HoloOutcome.Failed, HoloOutcome.From(saved: false, opened: false, copied: false, shown: false));
        Assert.Equal(HoloOutcome.SavedOpened, HoloOutcome.Parse("saved_opened"));
        Assert.Null(HoloOutcome.Parse("nope"));
    }

    [Fact]
    public void BeaconBits()
    {
        Assert.Equal(20, HoloBeaconCode.ChirpBits("0x1234").Count);
        Assert.Equal(new[] { true, false, true, false }, HoloBeaconCode.ChirpBits("0x1234").Take(4));
        Assert.Equal((ushort)0x1234, HoloBeaconCode.Code16("0x1234"));
        Assert.Equal((ushort)1234, HoloBeaconCode.Code16("1234"));
        Assert.Equal(15, HoloBeaconCode.FlashFrames("0x1234").Count);
        // 0x1234 = 0001 0010 0011 0100, MSB first after the preamble.
        Assert.Equal(new[] { false, false, false, true, false, false, true, false }, HoloBeaconCode.ChirpBits("0x1234").Skip(4).Take(8));
        Assert.Equal(0.015, HoloBeaconCode.ChirpSymbol);
        Assert.Equal(18500, HoloBeaconCode.ZeroHz);
        Assert.Equal(19500, HoloBeaconCode.OneHz);
        Assert.Equal(10, HoloBeaconCode.FlashHz);
    }

    [Fact]
    public void Beacon_NonHexNonceHashes() =>
        Assert.Equal((ushort)(HoloBle.Fnv1a("hello-nonce") & 0xFFFF), HoloBeaconCode.Code16("hello-nonce"));

    [Fact]
    public void ChirpSamples_LengthAndSoftEdges()
    {
        var s = HoloBeaconCode.ChirpSamples("0x1234", 48_000);
        Assert.Equal(720 * 20, s.Length);
        Assert.Equal(0f, s[0]);
        Assert.True(s.Max() <= 0.25f + 1e-6);
    }

    [Fact]
    public void Ble_NameAndPayload()
    {
        Assert.Equal("HD" + HoloBle.Fnv1a("dev-1").ToString("x8"), HoloBle.LocalName("dev-1"));
        var p = HoloBle.ManufacturerPayload("dev-1");
        Assert.Equal((byte)'H', p[0]);
        Assert.Equal(6, p.Length);
        Assert.Equal((byte)'D', p[1]);
        var h = HoloBle.Fnv1a("dev-1");
        Assert.Equal(new[] { (byte)(h >> 24), (byte)(h >> 16), (byte)(h >> 8), (byte)h }, p.Skip(2));
        Assert.Equal(0xFFFF, HoloBle.CompanyId);
        Assert.Equal(new Guid("6F1D5A3E-9C2B-4E7A-8D11-3B6A2C9E0F42"), HoloBle.Service);
        Assert.Equal(2166136261u, HoloBle.Fnv1a(""));
    }

    [Fact]
    public void SafeName_And_Unique()
    {
        Assert.Equal("a-b", HoloFiles.SafeName("a/b"));
        Assert.Equal("x 2.png", HoloFiles.Unique("x.png", n => n == "x.png"));
        Assert.Equal("x 3.png", HoloFiles.Unique("x.png", n => n is "x.png" or "x 2.png"));
        Assert.Equal("free.png", HoloFiles.Unique("free.png", _ => false));
    }

    [Fact]
    public void SafeName_WindowsRules()
    {
        Assert.Equal("a-b-c", HoloFiles.SafeName("a\\b:c"));
        Assert.Equal("Holo Drop", HoloFiles.SafeName("..."));
        Assert.Equal("hidden", HoloFiles.SafeName(".hidden"));
        Assert.Equal("bell.txt", HoloFiles.SafeName("bell\u0007.txt"));
        Assert.Equal("_CON.txt", HoloFiles.SafeName("CON.txt"));
        Assert.Equal("trail", HoloFiles.SafeName("trail. "));
        var longName = HoloFiles.SafeName(new string('a', 200) + ".jpeg");
        Assert.Equal(120, longName.Length);
        Assert.EndsWith(".jpeg", longName);
    }

    [Fact]
    public void Landing_Steps()
    {
        Assert.Equal((true, false, false), HoloLanding.Steps(HoloAction.Save));
        Assert.Equal((false, true, false), HoloLanding.Steps(HoloAction.Open));
        Assert.Equal((false, false, true), HoloLanding.Steps(HoloAction.Copy));
        Assert.Equal((true, true, false), HoloLanding.Steps(HoloAction.SaveOpen));
        Assert.Equal((true, false, true), HoloLanding.Steps(HoloAction.SaveCopy));
        Assert.Equal("[InternetShortcut]\r\nURL=https://x.com/a\r\n", HoloLanding.LinkFileBody("https://x.com/a"));
    }

    [Fact]
    public void Landing_ExecutablesNeverOpenThemselves()
    {
        Assert.True(HoloLanding.IsExecutable("setup.exe", ""));
        Assert.True(HoloLanding.IsExecutable("run.ps1\u0007", ""));
        Assert.True(HoloLanding.IsExecutable("x.lnk ", ""));
        Assert.False(HoloLanding.IsExecutable("photo.jpg", "image/jpeg"));
        var drop = HoloDropRecord.FromJson(J.Parse("{\"id\":\"d\",\"kind\":\"file\",\"name\":\"a.exe\"}"))!;
        var plan = HoloLanding.Plan(drop, HoloAction.Open, executable: true);
        Assert.False(plan.Open);
        Assert.True(plan.OpenHeld);
        Assert.True(plan.Fetch);
        var odd = HoloDropRecord.FromJson(J.Parse("{\"id\":\"d\",\"kind\":\"link\",\"url\":\"ms-settings:privacy\"}"))!;
        Assert.True(HoloLanding.Plan(odd, HoloAction.Open).OpenHeld);
        var text = HoloDropRecord.FromJson(J.Parse("{\"id\":\"d\",\"kind\":\"text\",\"text\":\"hello there\"}"))!;
        Assert.True(HoloLanding.Plan(text, HoloAction.Open).Show);
    }

    [Fact]
    public void Record_ParsesAndNames()
    {
        var d = HoloDropRecord.FromJson(J.Parse(
            "{\"id\":\"d1\",\"kind\":\"link\",\"sender\":\"iphone-1\",\"url\":\"https://github.com/x\",\"action\":\"save_open\",\"position\":{\"x\":1.4,\"y\":0.25},\"created\":1763208000}"))!;
        Assert.Equal("iphone-1", d.From);
        Assert.Equal(HoloAction.SaveOpen, d.Action);
        Assert.Equal(new HoloPosition(1, 0.25), d.Position);
        Assert.Equal("github.com", d.DisplayName);
        Assert.Equal("https://github.com/x", d.WebUrl!.AbsoluteUri);
        Assert.Null(HoloDropRecord.FromJson(J.Parse("{\"kind\":\"zip\"}")));
        Assert.Equal("Landed on iPhone · Saved", HoloDropRecord.LandedLine("iPhone", "saved"));
        Assert.Equal("Didn't land on iPhone — full", HoloDropRecord.LandedLine("iPhone", "failed", "full"));
    }

    [Fact]
    public void Device_ParsesLanAndDefaults()
    {
        var list = HoloDevice.List(J.Parse(
            "{\"devices\":[{\"id\":\"p1\",\"kind\":\"iphone\",\"name\":\"iPhone\",\"online\":true,\"default_action\":\"save\",\"lan\":{\"url\":\"http://192.168.1.30:5000\",\"token\":\"t\",\"expires\":0},\"bearing\":{\"deg\":45,\"confidence\":0.8}},{\"id\":\"\"},{\"id\":\"m1\"}]}"));
        Assert.Equal(2, list.Count);
        Assert.Equal(HoloAction.Save, list[0].DefaultAction);
        Assert.True(list[0].Lan!.Usable(DateTimeOffset.UtcNow));
        Assert.Equal(45, list[0].Bearing);
        Assert.Equal("Mac", list[1].Name);
        Assert.Equal(HoloAction.Open, list[1].DefaultAction);
        Assert.False(new HoloLan("http://x", "t", 100).Usable(DateTimeOffset.FromUnixTimeSeconds(200)));
    }

    [Fact]
    public void Item_FromText_LinkOrText()
    {
        Assert.Equal(HoloItem.Link("https://a.com/b"), HoloItem.FromText("  https://a.com/b \n"));
        Assert.Equal(HoloItem.Text("hello world"), HoloItem.FromText("hello world"));
        Assert.Null(HoloItem.FromText("  "));
        Assert.Equal(HoloItem.Files(new[] { "C:\\a.txt" }), HoloItem.Files(new[] { "C:\\a.txt" }));
    }

    [Fact]
    public void InlineDrop_DirectCarriesOutcome()
    {
        var body = HoloWire.InlineDrop(HoloKind.File, "p1", action: HoloAction.Save, direct: true, name: "a.txt",
            mime: "text/plain", outcome: HoloOutcome.Saved);
        Assert.Equal("{\"action\":\"save\",\"delivered_direct\":true,\"kind\":\"file\",\"mime\":\"text/plain\",\"name\":\"a.txt\",\"outcome\":\"saved\",\"target\":\"p1\"}",
            J.SortedJson(body));
        var plain = HoloWire.InlineDrop(HoloKind.Text, "p1", text: "hi", action: null, outcome: HoloOutcome.Saved);
        Assert.Equal("{\"kind\":\"text\",\"target\":\"p1\",\"text\":\"hi\"}", J.SortedJson(plain));
    }

    [Fact]
    public void Meta_RoundTrips_SortedKeys()
    {
        var m = HoloWire.Meta(new JsonObject { ["kind"] = "text", ["action"] = "copy" });
        Assert.Equal("{\"action\":\"copy\",\"kind\":\"text\"}", Encoding.UTF8.GetString(Convert.FromBase64String(m)));
        Assert.Equal("text", J.S(HoloWire.DecodeMeta(" " + m + " ")!["kind"]));
        Assert.Null(HoloWire.DecodeMeta("!!"));
        Assert.Null(HoloWire.DecodeMeta(null));
    }

    [Fact]
    public void LanAdvert_And_Landed()
    {
        Assert.Equal("{\"expires\":1763208000,\"token\":\"tok\",\"url\":\"http://192.168.1.20:5123\"}",
            J.SortedJson(HoloWire.LanAdvert("http://192.168.1.20:5123", "tok", DateTimeOffset.FromUnixTimeSeconds(1763208000))));
        Assert.Equal("{\"outcome\":\"saved\"}", HoloWire.Landed(HoloOutcome.Saved).ToJsonString());
        Assert.Equal("{\"error\":\"x\",\"outcome\":\"failed\"}", J.SortedJson(HoloWire.Landed(HoloOutcome.Failed, "x")));
    }

    [Fact]
    public void Outlines_ClipAndSkip()
    {
        var display = new RectI(0, 0, 2000, 1000);
        var o = HoloGeometry.Outlines(new[]
        {
            (new RectI(-100, 0, 900, 500), "Chrome"),
            (new RectI(10, 10, 30, 30), "Tiny"),
            (new RectI(100, 100, 600, 600), ""),
            (new RectI(3000, 0, 3500, 500), "Off"),
        }, display);
        var only = Assert.Single(o);
        Assert.Equal(new HoloWindowOutline(0, 0, 0.45, 0.5, "Chrome"), only);
    }

    [Fact]
    public void LanAddress_PicksGatewayInterface_NeverTailscaleOrLinkLocal()
    {
        Assert.Equal("192.168.1.20", HoloLanAddress.Pick(new[]
        {
            new HoloLanCandidate("Tailscale", "100.101.1.2", true, true, true),
            new HoloLanCandidate("vEthernet", "172.20.0.1", true, true, false),
            new HoloLanCandidate("Ethernet 2", "169.254.3.4", true, true, true),
            new HoloLanCandidate("Wi-Fi", "192.168.1.20", true, true, true),
        }));
        Assert.Null(HoloLanAddress.Pick(new[] { new HoloLanCandidate("lo", "127.0.0.1", true, true, true) }));
        Assert.Equal("100.128.0.1", HoloLanAddress.Pick(new[] { new HoloLanCandidate("Ethernet", "100.128.0.1", true, true, true) }));
    }

    [Fact]
    public void Http_ParseHead()
    {
        var raw = Encoding.ASCII.GetBytes("post /holo-drop?x=1 HTTP/1.1\r\nX-Holo-Token: abc\r\nContent-Length: 12\r\n\r\nrest");
        var end = HoloHttp.HeadEnd(raw, raw.Length);
        Assert.Equal(raw.Length - 4, end);
        var h = HoloHttp.Parse(raw.AsSpan(0, end!.Value))!;
        Assert.Equal("POST", h.Method);
        Assert.Equal("/holo-drop", h.Path);
        Assert.Equal("abc", h.Headers["x-holo-token"]);
        Assert.Equal(12, h.ContentLength);
        Assert.True(HoloHttp.SameToken("abc", "abc"));
        Assert.False(HoloHttp.SameToken("abc", "abd"));
        Assert.False(HoloHttp.SameToken("", ""));
        Assert.StartsWith("HTTP/1.1 413 Payload Too Large\r\n", Encoding.ASCII.GetString(HoloHttp.Response(413, new JsonObject())));
    }

    [Fact]
    public void Temp_SweepsOnlyOldHoloFolders()
    {
        var root = Tmp.Dir();
        var old = Directory.CreateDirectory(Path.Combine(root, "HoloDrop-lan-1")).FullName;
        var fresh = Directory.CreateDirectory(Path.Combine(root, "HoloDrop-lan-2")).FullName;
        var mine = Directory.CreateDirectory(Path.Combine(root, "Other")).FullName;
        var now = DateTime.UtcNow;
        Directory.SetLastWriteTimeUtc(old, now.AddDays(-2));
        Directory.SetLastWriteTimeUtc(mine, now.AddDays(-2));
        HoloTemp.Sweep(root, TimeSpan.FromDays(1), now);
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(fresh));
        Assert.True(Directory.Exists(mine));
    }

    [Fact]
    public void CardLayout_AtPositionElseBottomRight()
    {
        var work = new RectI(0, 0, 1920, 1040);
        var at = HoloCardLayout.Frame(new HoloPosition(0.5, 0.5), work, 300, 200);
        Assert.Equal(new RectI(810, 420, 1110, 620), at);
        var corner = HoloCardLayout.Frame(null, work, 300, 200);
        Assert.Equal(new RectI(1604, 824, 1904, 1024), corner);
        var clamped = HoloCardLayout.Frame(new HoloPosition(0, 0), work, 300, 200);
        Assert.Equal(new RectI(8, 8, 308, 208), clamped);
        Assert.InRange(HoloCardLayout.HeroSize(10).Width, 240, 420);
        Assert.InRange(HoloCardLayout.HeroSize(0.1).Width, 240, 420);
    }
}
