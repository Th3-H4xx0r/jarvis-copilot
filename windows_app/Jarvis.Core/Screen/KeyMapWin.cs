namespace Jarvis.Core.Screen;

/// Windows virtual-key codes for the viewer's key names (KeyboardEvent.key) and physical codes
/// (KeyboardEvent.code). Port of InputInjector.keyCode with the Mac codes swapped for VKs.
/// "Delete" with no code is Backspace (the iPhone's ⌫); with code "Delete" it's forward delete.
public static class KeyMapWin
{
    public const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12;

    private static readonly Dictionary<string, ushort> Physical = new()
    {
        ["Minus"] = 0xBD, ["Equal"] = 0xBB, ["BracketLeft"] = 0xDB, ["BracketRight"] = 0xDD, ["Backslash"] = 0xDC,
        ["Semicolon"] = 0xBA, ["Quote"] = 0xDE, ["Backquote"] = 0xC0, ["Comma"] = 0xBC, ["Period"] = 0xBE, ["Slash"] = 0xBF,
        ["IntlBackslash"] = 0xE2, ["Space"] = 0x20, ["Enter"] = 0x0D, ["NumpadEnter"] = 0x0D, ["Tab"] = 0x09,
        ["Backspace"] = 0x08, ["Delete"] = 0x2E, ["Escape"] = 0x1B, ["Home"] = 0x24, ["End"] = 0x23,
        ["PageUp"] = 0x21, ["PageDown"] = 0x22, ["ArrowLeft"] = 0x25, ["ArrowUp"] = 0x26, ["ArrowRight"] = 0x27, ["ArrowDown"] = 0x28,
    };

    private static readonly Dictionary<string, ushort> Named = new()
    {
        ["return"] = 0x0D, ["enter"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20, [" "] = 0x20, ["backspace"] = 0x08, ["delete"] = 0x08,
        ["escape"] = 0x1B, ["esc"] = 0x1B, ["forwarddelete"] = 0x2E, ["home"] = 0x24, ["end"] = 0x23, ["pageup"] = 0x21,
        ["pagedown"] = 0x22, ["arrowleft"] = 0x25, ["left"] = 0x25, ["arrowright"] = 0x27, ["right"] = 0x27,
        ["arrowdown"] = 0x28, ["down"] = 0x28, ["arrowup"] = 0x26, ["up"] = 0x26,
    };

    private static readonly Dictionary<char, ushort> Chars = new()
    {
        ['='] = 0xBB, ['-'] = 0xBD, [']'] = 0xDD, ['['] = 0xDB, ['\''] = 0xDE, [';'] = 0xBA, ['\\'] = 0xDC,
        [','] = 0xBC, ['/'] = 0xBF, ['.'] = 0xBE, ['`'] = 0xC0,
    };

    /// The key to press: the physical `code` for shortcuts and named keys when one was sent,
    /// else the `name` / character. Null when there's no key for it.
    public static ushort? Vk(string name, string code, bool shortcut)
    {
        if (code.Length > 0 && (shortcut || name.Length != 1) && PhysicalVk(code) is { } p) return p;
        return NamedVk(name);
    }

    public static ushort? PhysicalVk(string code)
    {
        if (code.StartsWith("Key", StringComparison.Ordinal) && code.Length == 4 && char.IsAsciiLetter(code[3])) return char.ToUpperInvariant(code[3]);
        if (code.StartsWith("Digit", StringComparison.Ordinal) && code.Length == 6 && char.IsAsciiDigit(code[5])) return code[5];
        if (Physical.TryGetValue(code, out var v)) return v;
        if (code.Length >= 2 && code[0] == 'F' && int.TryParse(code[1..], out var n) && n is >= 1 and <= 12) return (ushort)(0x6F + n);
        return null;
    }

    public static ushort? NamedVk(string name)
    {
        var lower = name.ToLowerInvariant();
        if (Named.TryGetValue(lower, out var v)) return v;
        if (lower.Length >= 2 && lower[0] == 'f' && int.TryParse(lower[1..], out var n) && n is >= 1 and <= 12) return (ushort)(0x6F + n);
        if (name.Length != 1) return null;
        var c = lower[0];
        if (char.IsAsciiLetterLower(c)) return char.ToUpperInvariant(c);
        if (char.IsAsciiDigit(c)) return c;
        return Chars.TryGetValue(c, out var oem) ? oem : null;
    }

    /// cmd/command/meta and ctrl/control → Ctrl (so ⌘C is Ctrl+C), shift, alt/option → Alt; deduped, in that order.
    public static ushort[] ModVks(IReadOnlyList<string> mods)
    {
        bool ctrl = false, shift = false, alt = false;
        foreach (var m in mods)
        {
            switch (m.ToLowerInvariant())
            {
                case "cmd" or "command" or "meta" or "ctrl" or "control": ctrl = true; break;
                case "shift": shift = true; break;
                case "alt" or "option" or "opt": alt = true; break;
            }
        }
        var o = new List<ushort>();
        if (ctrl) o.Add(VK_CONTROL);
        if (shift) o.Add(VK_SHIFT);
        if (alt) o.Add(VK_MENU);
        return o.ToArray();
    }

    /// Keys SendInput must flag KEYEVENTF_EXTENDEDKEY (arrows, Home/End, PgUp/PgDn, Ins/Del).
    public static bool IsExtended(ushort vk) => vk is >= 0x21 and <= 0x28 or 0x2D or 0x2E;
}
