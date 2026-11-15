namespace Jarvis.Core.Input;

/// RegisterHotKey's modifier bits (MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8).
[Flags]
public enum ModifierKeys : uint { None = 0, Alt = 1, Control = 2, Shift = 4, Windows = 8 }

/// A global chord: one virtual key plus modifiers. Stored as "ctrl+alt+h". A plain key needs at
/// least one modifier (so typing is never swallowed); F13–F24 and F1–F12 may stand alone.
public readonly record struct Shortcut(uint Vk, ModifierKeys Mods)
{
    private static readonly (string Name, ModifierKeys Mod)[] ModNames =
    {
        ("ctrl", ModifierKeys.Control), ("alt", ModifierKeys.Alt), ("shift", ModifierKeys.Shift), ("win", ModifierKeys.Windows),
    };

    private static readonly Dictionary<string, uint> Named = new(StringComparer.OrdinalIgnoreCase)
    {
        ["space"] = 0x20, ["enter"] = 0x0D, ["tab"] = 0x09, ["esc"] = 0x1B, ["backspace"] = 0x08, ["delete"] = 0x2E,
        ["up"] = 0x26, ["down"] = 0x28, ["left"] = 0x25, ["right"] = 0x27, ["home"] = 0x24, ["end"] = 0x23,
        ["pageup"] = 0x21, ["pagedown"] = 0x22, ["insert"] = 0x2D,
        ["["] = 0xDB, ["]"] = 0xDD, [";"] = 0xBA, ["'"] = 0xDE, [","] = 0xBC, ["."] = 0xBE, ["/"] = 0xBF,
        ["\\"] = 0xDC, ["-"] = 0xBD, ["="] = 0xBB, ["`"] = 0xC0,
    };

    public bool IsFunctionKey => Vk is >= 0x70 and <= 0x87;

    public static Shortcut? Parse(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Trim().ToLowerInvariant().Split('+');
        var mods = ModifierKeys.None;
        uint? vk = null;
        for (var i = 0; i < parts.Length; i++)
        {
            var p = parts[i].Trim();
            // "ctrl++" → the last empty part is a literal '+', which isn't supported.
            if (p.Length == 0) return null;
            var mod = p switch
            {
                "ctrl" or "control" => ModifierKeys.Control,
                "alt" or "opt" or "option" => ModifierKeys.Alt,
                "shift" => ModifierKeys.Shift,
                "win" or "meta" or "cmd" => ModifierKeys.Windows,
                _ => ModifierKeys.None,
            };
            if (mod != ModifierKeys.None && i < parts.Length - 1) { mods |= mod; continue; }
            if (i != parts.Length - 1 || vk != null) return null;
            vk = KeyVk(p);
            if (vk == null) return null;
        }
        if (vk is not { } key) return null;
        var sc = new Shortcut(key, mods);
        if (mods == ModifierKeys.None && !sc.IsFunctionKey) return null;
        return sc;
    }

    private static uint? KeyVk(string p)
    {
        if (p.Length == 1 && p[0] is >= 'a' and <= 'z') return (uint)char.ToUpperInvariant(p[0]);
        if (p.Length == 1 && p[0] is >= '0' and <= '9') return p[0];
        if (p.Length is 2 or 3 && p[0] == 'f' && int.TryParse(p[1..], out var n) && n is >= 1 and <= 24) return (uint)(0x70 + n - 1);
        return Named.TryGetValue(p, out var v) ? v : null;
    }

    private string KeyName(bool display)
    {
        if (Vk is >= 'A' and <= 'Z') return display ? ((char)Vk).ToString() : ((char)Vk).ToString().ToLowerInvariant();
        if (Vk is >= '0' and <= '9') return ((char)Vk).ToString();
        if (IsFunctionKey) return (display ? "F" : "f") + (Vk - 0x70 + 1);
        var vk = Vk;
        var name = Named.FirstOrDefault(kv => kv.Value == vk).Key ?? $"vk{vk}";
        return display && name.Length > 1 ? char.ToUpperInvariant(name[0]) + name[1..] : name;
    }

    public string ToPrefString()
    {
        var mods = Mods;
        return string.Join("+", ModNames.Where(m => mods.HasFlag(m.Mod)).Select(m => m.Name).Append(KeyName(false)));
    }

    public string Display()
    {
        var mods = Mods;
        return string.Join("+", ModNames.Where(m => mods.HasFlag(m.Mod)).Select(m => m.Name switch
        {
            "ctrl" => "Ctrl", "alt" => "Alt", "shift" => "Shift", _ => "Win",
        }).Append(KeyName(true)));
    }
}

public enum ShortcutAction
{
    ToggleIsland, OpenChat, GoToAlert, JumpToTerminal, AttachWindow, NextSession, PreviousSession, Mute, DesktopOrb,
    NextSkin, RecordCall, HoloDrop,
}

public static class ShortcutActions
{
    public static readonly IReadOnlyList<ShortcutAction> All = Enum.GetValues<ShortcutAction>();

    /// The Mac's chords with ⌃⌥ → Ctrl+Alt.
    public static Shortcut? Default(this ShortcutAction a) => a switch
    {
        ShortcutAction.OpenChat => Shortcut.Parse("ctrl+alt+space"),
        ShortcutAction.GoToAlert => Shortcut.Parse("ctrl+alt+a"),
        ShortcutAction.JumpToTerminal => Shortcut.Parse("ctrl+alt+t"),
        ShortcutAction.AttachWindow => Shortcut.Parse("ctrl+alt+w"),
        ShortcutAction.NextSession => Shortcut.Parse("ctrl+alt+]"),
        ShortcutAction.PreviousSession => Shortcut.Parse("ctrl+alt+["),
        ShortcutAction.Mute => Shortcut.Parse("ctrl+alt+m"),
        ShortcutAction.DesktopOrb => Shortcut.Parse("ctrl+alt+d"),
        ShortcutAction.NextSkin => Shortcut.Parse("ctrl+alt+g"),
        ShortcutAction.HoloDrop => Shortcut.Parse("ctrl+alt+h"),
        _ => null,
    };

    public static string Title(this ShortcutAction a) => a switch
    {
        ShortcutAction.ToggleIsland => "Show or hide the island",
        ShortcutAction.OpenChat => "Open the chat",
        ShortcutAction.GoToAlert => "Go to what needs you",
        ShortcutAction.JumpToTerminal => "Jump to the session's terminal",
        ShortcutAction.AttachWindow => "Attach the front window to the chat",
        ShortcutAction.NextSession => "Next session",
        ShortcutAction.PreviousSession => "Previous session",
        ShortcutAction.Mute => "Mute sounds",
        ShortcutAction.DesktopOrb => "Orb on the desktop",
        ShortcutAction.NextSkin => "Next orb look",
        ShortcutAction.RecordCall => "Record a call (start / stop)",
        _ => "Holo Drop what's in front",
    };

    public static string PrefKey(this ShortcutAction a) => "shortcut." + char.ToLowerInvariant(a.ToString()[0]) + a.ToString()[1..];

    /// His binding: the default if never set, null when he switched it off ("").
    public static Shortcut? Binding(this ShortcutAction a, Prefs.PrefsStore prefs)
    {
        var raw = prefs.Get<string?>(a.PrefKey(), null);
        return raw == null ? a.Default() : Shortcut.Parse(raw);
    }

    public static void SetBinding(this ShortcutAction a, Prefs.PrefsStore prefs, Shortcut? s) =>
        prefs.Set(a.PrefKey(), s?.ToPrefString() ?? "");

    /// Two actions on one chord: the later one loses (RegisterHotKey would refuse it anyway).
    public static IReadOnlyList<(ShortcutAction A, ShortcutAction B)> Clashes(IReadOnlyDictionary<ShortcutAction, Shortcut?> bindings) =>
        bindings.Where(kv => kv.Value != null).GroupBy(kv => kv.Value)
            .Where(g => g.Count() > 1)
            .SelectMany(g => g.Skip(1).Select(x => (g.First().Key, x.Key))).ToList();
}
