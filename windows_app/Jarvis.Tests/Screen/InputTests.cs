using Jarvis.Core.Gaming;
using Jarvis.Core.Link;
using Jarvis.Core.Screen;
using static Jarvis.Core.Screen.InputEvent;

namespace Jarvis.Tests.Screen;

public class InputTests
{
    private static readonly RectI Display = new(1920, 0, 3840, 1080);
    private static readonly RectI Virtual = new(0, 0, 3840, 1080);

    private static IReadOnlyList<InputEvent> Map(string json) => InputMapper.Map(InputMessage.Parse(J.Parse(json))!, Display, Virtual);

    [Fact]
    public void Parse_AllKinds()
    {
        Assert.Equal(new InputMessage.Move(0.5, 0.25), InputMessage.Parse(J.Parse("{\"t\":\"move\",\"x\":0.5,\"y\":0.25}")));
        Assert.Equal(new InputMessage.Down(0.1, 0.2, "right"), InputMessage.Parse(J.Parse("{\"t\":\"down\",\"x\":0.1,\"y\":0.2,\"button\":\"right\"}")));
        Assert.Equal(new InputMessage.Up(0.1, 0.2, "left"), InputMessage.Parse(J.Parse("{\"t\":\"up\",\"x\":0.1,\"y\":0.2}")));
        Assert.Equal(new InputMessage.Click(0.1, 0.2, "left", 1), InputMessage.Parse(J.Parse("{\"t\":\"click\",\"x\":0.1,\"y\":0.2,\"count\":0}")));
        Assert.Equal(new InputMessage.Scroll(0, 120), InputMessage.Parse(J.Parse("{\"t\":\"scroll\",\"dy\":120}")));
        var key = (InputMessage.Key)InputMessage.Parse(J.Parse("{\"t\":\"key\",\"key\":\"c\",\"mods\":[\"cmd\"],\"code\":\"KeyC\"}"))!;
        Assert.Equal(("c", "KeyC"), (key.Name, key.Code));
        Assert.Equal(new[] { "cmd" }, key.Mods);
        Assert.Equal(new InputMessage.Text("hi"), InputMessage.Parse(J.Parse("{\"t\":\"text\",\"text\":\"hi\"}")));
        Assert.Null(InputMessage.Parse(J.Parse("{\"t\":\"cc\",\"do\":\"state\"}")));
    }

    [Fact]
    public void Input_ClickMapsToAbsoluteVirtualDesk()
    {
        var e = Map("{\"t\":\"click\",\"x\":0.5,\"y\":0.5,\"button\":\"left\"}");
        Assert.Equal(3, e.Count);
        Assert.Equal(MouseMove | MouseAbsolute | MouseVirtualDesk, e[0].Flags);
        Assert.Equal((2880 * 65535) / 3839, e[0].Dx);
        Assert.Equal((540 * 65535) / 1079, e[0].Dy);
        Assert.Equal(MouseLeftDown, e[1].Flags);
        Assert.Equal(MouseLeftUp, e[2].Flags);
        Assert.All(e, x => Assert.Equal(InputKind.Mouse, x.Kind));
    }

    [Fact]
    public void Input_RightClickAndClamp()
    {
        var e = Map("{\"t\":\"click\",\"x\":5,\"y\":-1,\"button\":\"right\"}");
        Assert.Equal(65535, e[0].Dx);
        Assert.Equal(0, e[0].Dy);
        Assert.Equal(MouseRightDown, e[1].Flags);
        Assert.Equal(MouseRightUp, e[2].Flags);
    }

    [Fact]
    public void Input_ClickCount2_TwoPairs()
    {
        var e = Map("{\"t\":\"click\",\"x\":0.5,\"y\":0.5,\"count\":2}");
        Assert.Equal(new[] { MouseLeftDown, MouseLeftUp, MouseLeftDown, MouseLeftUp }, e.Skip(1).Select(x => x.Flags));
        Assert.Equal(7, Map("{\"t\":\"click\",\"x\":0.5,\"y\":0.5,\"count\":9}").Count);
    }

    [Fact]
    public void Input_DownUpMoveThenButton()
    {
        var d = Map("{\"t\":\"down\",\"x\":0.5,\"y\":0.5}");
        Assert.Equal(new[] { MouseMove | MouseAbsolute | MouseVirtualDesk, MouseLeftDown }, d.Select(x => x.Flags));
        var m = Map("{\"t\":\"move\",\"x\":0.5,\"y\":0.5}");
        Assert.Single(m);
    }

    [Fact]
    public void Input_ScrollInvertedAndClamped()
    {
        var e = Map("{\"t\":\"scroll\",\"dy\":120}");
        Assert.Equal(MouseWheel, e.Single().Flags);
        Assert.Equal(-120, e.Single().MouseData);
        Assert.Equal(-2000, Map("{\"t\":\"scroll\",\"dy\":99999}").Single().MouseData);
        var h = Map("{\"t\":\"scroll\",\"dx\":50}").Single();
        Assert.Equal(MouseHWheel, h.Flags);
        Assert.Equal(50, h.MouseData);
    }

    [Fact]
    public void Key_CmdCBecomesCtrlC()
    {
        var e = Map("{\"t\":\"key\",\"key\":\"c\",\"mods\":[\"cmd\"],\"code\":\"KeyC\"}");
        Assert.Equal(new (ushort, bool)[] { (0x11, false), (0x43, false), (0x43, true), (0x11, true) },
            e.Select(x => (x.Vk, (x.Flags & KeyUp) != 0)));
    }

    [Fact]
    public void Key_ShiftAltAndDedupedCtrl()
    {
        var e = Map("{\"t\":\"key\",\"key\":\"ArrowLeft\",\"mods\":[\"ctrl\",\"meta\",\"shift\",\"alt\"],\"code\":\"ArrowLeft\"}");
        Assert.Equal(new ushort[] { 0x11, 0x10, 0x12, 0x25, 0x25, 0x12, 0x10, 0x11 }, e.Select(x => x.Vk));
        Assert.True((e[3].Flags & KeyExtended) != 0);
    }

    [Fact]
    public void Key_PlainCharTypedAsUnicode()
    {
        var e = Map("{\"t\":\"key\",\"key\":\"A\"}");
        Assert.Equal(2, e.Count);
        Assert.All(e, x => { Assert.Equal(InputKind.Keyboard, x.Kind); Assert.Equal((ushort)'A', x.Scan); Assert.Equal((ushort)0, x.Vk); Assert.True((x.Flags & KeyUnicode) != 0); });
        Assert.True((e[1].Flags & KeyUp) != 0);
    }

    [Fact]
    public void Key_DeleteWithoutCodeIsBackspace_WithCodeIsForwardDelete()
    {
        Assert.Equal((ushort)0x08, Map("{\"t\":\"key\",\"key\":\"Delete\"}")[0].Vk);
        Assert.Equal((ushort)0x2E, Map("{\"t\":\"key\",\"key\":\"Delete\",\"code\":\"Delete\"}")[0].Vk);
        Assert.Equal((ushort)0x2E, Map("{\"t\":\"key\",\"key\":\"ForwardDelete\"}")[0].Vk);
    }

    [Fact]
    public void Key_NamedAndPhysical()
    {
        Assert.Equal((ushort)0x0D, KeyMapWin.Vk("Enter", "", false));
        Assert.Equal((ushort)0x71, KeyMapWin.Vk("F2", "", false));
        Assert.Equal((ushort)0xDB, KeyMapWin.Vk("ƒ", "BracketLeft", true));
        Assert.Equal((ushort)0x31, KeyMapWin.Vk("!", "Digit1", true));
        Assert.Null(KeyMapWin.Vk("é", "", false));
        Assert.Equal(new ushort[] { 0x11, 0x10 }, KeyMapWin.ModVks(new[] { "cmd", "control", "shift" }));
    }

    [Fact]
    public void Key_UnknownCharWithoutModsIsTyped()
    {
        var e = Map("{\"t\":\"key\",\"key\":\"é\",\"mods\":[\"shift\"]}");
        Assert.True(e.All(x => (x.Flags & KeyUnicode) != 0));
    }

    [Fact]
    public void Text_ChunkedUnicode_Max4000()
    {
        var e = Map("{\"t\":\"text\",\"text\":\"" + new string('x', 5000) + "\"}");
        Assert.Equal(8000, e.Count);
        Assert.All(e, x => Assert.True((x.Flags & KeyUnicode) != 0));
        Assert.Equal(4, Map("{\"t\":\"text\",\"text\":\"hi\"}").Count);
    }
}
