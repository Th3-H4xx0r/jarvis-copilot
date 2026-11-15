using System.Globalization;
using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Link;

namespace Jarvis.Core.Screen;

/// The viewer's mouse and keys on data channel "input" (InputInjector.swift's contract).
/// Coordinates are normalised (0…1) to the shared display.
public abstract record InputMessage
{
    public sealed record Move(double X, double Y) : InputMessage;
    public sealed record Down(double X, double Y, string Button) : InputMessage;
    public sealed record Up(double X, double Y, string Button) : InputMessage;
    public sealed record Click(double X, double Y, string Button, int Count) : InputMessage;
    public sealed record Scroll(double Dx, double Dy) : InputMessage;
    public sealed record Key(string Name, IReadOnlyList<string> Mods, string Code) : InputMessage;
    public sealed record Text(string Value) : InputMessage;

    public static InputMessage? Parse(JsonObject m)
    {
        double X() => J.D(m["x"]) ?? 0.5;
        double Y() => J.D(m["y"]) ?? 0.5;
        string Button() => J.S(m["button"]) == "right" ? "right" : "left";
        return J.S(m["t"]) switch
        {
            "move" => new Move(X(), Y()),
            "down" => new Down(X(), Y(), Button()),
            "up" => new Up(X(), Y(), Button()),
            "click" => new Click(X(), Y(), Button(), Math.Clamp(J.I(m["count"]) == 0 ? 1 : J.I(m["count"]), 1, 3)),
            "scroll" => new Scroll(J.D(m["dx"]) ?? 0, J.D(m["dy"]) ?? 0),
            "key" => new Key(J.S(m["key"]), (m["mods"] as JsonArray)?.Select(x => J.S(x)).Where(x => x.Length > 0).ToList() ?? new List<string>(), J.S(m["code"])),
            "text" => new Text(J.S(m["text"])),
            _ => null,
        };
    }
}

public enum InputKind { Mouse, Keyboard }

/// One Win32 INPUT, OS-neutral so the mapping is testable anywhere; the app's SendInput sink
/// copies it into Native.INPUT. Flag values are the Win32 MOUSEEVENTF_* / KEYEVENTF_* bits.
public readonly record struct InputEvent(InputKind Kind, int Dx, int Dy, int MouseData, uint Flags, ushort Vk, ushort Scan)
{
    public const uint MouseMove = 0x0001, MouseLeftDown = 0x0002, MouseLeftUp = 0x0004, MouseRightDown = 0x0008,
        MouseRightUp = 0x0010, MouseWheel = 0x0800, MouseHWheel = 0x1000, MouseVirtualDesk = 0x4000, MouseAbsolute = 0x8000;
    public const uint KeyExtended = 0x0001, KeyUp = 0x0002, KeyUnicode = 0x0004;

    public static InputEvent Mouse(uint flags, int dx = 0, int dy = 0, int data = 0) => new(InputKind.Mouse, dx, dy, data, flags, 0, 0);
    public static InputEvent KeyVk(ushort vk, bool up) =>
        new(InputKind.Keyboard, 0, 0, 0, (up ? KeyUp : 0) | (KeyMapWin.IsExtended(vk) ? KeyExtended : 0), vk, 0);
    public static InputEvent KeyChar(char unit, bool up) => new(InputKind.Keyboard, 0, 0, 0, KeyUnicode | (up ? KeyUp : 0), 0, unit);
}

public interface IInputSink
{
    void Send(IReadOnlyList<InputEvent> inputs);
}

/// Viewer input → SendInput events. Absolute moves are normalised to the virtual desktop
/// (MOUSEEVENTF_VIRTUALDESK), so any monitor works; ⌘ on the phone is Ctrl on the PC.
public static class InputMapper
{
    public const int MaxText = 4000;

    public static IReadOnlyList<InputEvent> Map(InputMessage m, RectI display, RectI virtualDesktop)
    {
        var o = new List<InputEvent>();
        InputEvent MoveTo(double x, double y)
        {
            var px = display.Left + Math.Clamp(x, 0, 1) * display.Width;
            var py = display.Top + Math.Clamp(y, 0, 1) * display.Height;
            px = Math.Min(px, display.Right - 1);
            py = Math.Min(py, display.Bottom - 1);
            var dx = (int)((long)Math.Round(px - virtualDesktop.Left) * 65535 / Math.Max(1, virtualDesktop.Width - 1));
            var dy = (int)((long)Math.Round(py - virtualDesktop.Top) * 65535 / Math.Max(1, virtualDesktop.Height - 1));
            return InputEvent.Mouse(InputEvent.MouseMove | InputEvent.MouseAbsolute | InputEvent.MouseVirtualDesk, Math.Clamp(dx, 0, 65535), Math.Clamp(dy, 0, 65535));
        }
        static uint DownFlag(string b) => b == "right" ? InputEvent.MouseRightDown : InputEvent.MouseLeftDown;
        static uint UpFlag(string b) => b == "right" ? InputEvent.MouseRightUp : InputEvent.MouseLeftUp;

        switch (m)
        {
            case InputMessage.Move mv:
                o.Add(MoveTo(mv.X, mv.Y));
                break;
            case InputMessage.Down d:
                o.Add(MoveTo(d.X, d.Y));
                o.Add(InputEvent.Mouse(DownFlag(d.Button)));
                break;
            case InputMessage.Up u:
                o.Add(MoveTo(u.X, u.Y));
                o.Add(InputEvent.Mouse(UpFlag(u.Button)));
                break;
            case InputMessage.Click c:
                o.Add(MoveTo(c.X, c.Y));
                for (var i = 0; i < Math.Clamp(c.Count, 1, 3); i++)
                {
                    o.Add(InputEvent.Mouse(DownFlag(c.Button)));
                    o.Add(InputEvent.Mouse(UpFlag(c.Button)));
                }
                break;
            case InputMessage.Scroll s:
                // Browser deltas: positive dy = scroll down; the wheel's positive is up.
                if (s.Dy != 0) o.Add(InputEvent.Mouse(InputEvent.MouseWheel, data: (int)Math.Clamp(-s.Dy, -2000, 2000)));
                if (s.Dx != 0) o.Add(InputEvent.Mouse(InputEvent.MouseHWheel, data: (int)Math.Clamp(s.Dx, -2000, 2000)));
                break;
            case InputMessage.Key k:
                MapKey(k, o);
                break;
            case InputMessage.Text t:
                TypeText(t.Value, o);
                break;
        }
        return o;
    }

    private static void MapKey(InputMessage.Key k, List<InputEvent> o)
    {
        var mods = KeyMapWin.ModVks(k.Mods);
        var shortcut = mods.Any(v => v != KeyMapWin.VK_SHIFT);
        var single = new StringInfo(k.Name).LengthInTextElements == 1;
        // A plain character (maybe shifted) is typed as itself, so case and layout come out right.
        if (single && k.Name != " " && !shortcut)
        {
            TypeText(k.Name, o);
            return;
        }
        if (KeyMapWin.Vk(k.Name, k.Code, shortcut) is not { } vk)
        {
            // A character with no key on the layout (é, emoji…): type it instead.
            if (!shortcut && k.Name.Length > 0) TypeText(k.Name, o);
            return;
        }
        foreach (var m in mods) o.Add(InputEvent.KeyVk(m, false));
        o.Add(InputEvent.KeyVk(vk, false));
        o.Add(InputEvent.KeyVk(vk, true));
        for (var i = mods.Length - 1; i >= 0; i--) o.Add(InputEvent.KeyVk(mods[i], true));
    }

    private static void TypeText(string text, List<InputEvent> o)
    {
        var n = Math.Min(text.Length, MaxText);
        for (var i = 0; i < n; i++)
        {
            o.Add(InputEvent.KeyChar(text[i], false));
            o.Add(InputEvent.KeyChar(text[i], true));
        }
    }
}
