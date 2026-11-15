using Jarvis.Core.Gaming;
using Jarvis.Core.Input;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.Sounds;
using Jarvis.Core.State;
using Jarvis.Core.Terminal;
using Jarvis.Core.Tray;
using Jarvis.Tests.Fakes;
using Jarvis.Tests.Gaming;

namespace Jarvis.Tests.Input;

public class ShortcutTests
{
    [Fact]
    public void Parse_RoundTrips()
    {
        var s = Shortcut.Parse("ctrl+alt+h")!.Value;
        Assert.Equal("ctrl+alt+h", s.ToPrefString());
        Assert.Equal("Ctrl+Alt+H", s.Display());
        Assert.Equal((uint)'H', s.Vk);
        Assert.Equal(ModifierKeys.Control | ModifierKeys.Alt, s.Mods);
    }

    [Fact]
    public void Parse_PlainLetterRejected_F13Allowed()
    {
        Assert.Null(Shortcut.Parse("h"));
        Assert.NotNull(Shortcut.Parse("f13"));
        Assert.Equal(0x7Cu, Shortcut.Parse("f13")!.Value.Vk);
    }

    [Theory]
    [InlineData("")]
    [InlineData("ctrl+")]
    [InlineData("ctrl+alt")]
    [InlineData("ctrl+h+j")]
    [InlineData("ctrl+nope")]
    public void Parse_Garbage_Null(string s) => Assert.Null(Shortcut.Parse(s));

    [Fact] public void Parse_ModOrderNormalised() => Assert.Equal("ctrl+alt+space", Shortcut.Parse("alt+ctrl+space")!.Value.ToPrefString());
    [Fact] public void Parse_Brackets() => Assert.Equal("Ctrl+Alt+]", Shortcut.Parse("ctrl+alt+]")!.Value.Display());

    [Fact]
    public void Defaults_MatchMacChords()
    {
        Assert.Equal("ctrl+alt+space", ShortcutAction.OpenChat.Default()!.Value.ToPrefString());
        Assert.Equal("ctrl+alt+h", ShortcutAction.HoloDrop.Default()!.Value.ToPrefString());
        Assert.Equal("ctrl+alt+t", ShortcutAction.JumpToTerminal.Default()!.Value.ToPrefString());
        Assert.Equal("ctrl+alt+w", ShortcutAction.AttachWindow.Default()!.Value.ToPrefString());
        Assert.Equal("ctrl+alt+d", ShortcutAction.DesktopOrb.Default()!.Value.ToPrefString());
        Assert.Null(ShortcutAction.ToggleIsland.Default());
        Assert.Null(ShortcutAction.RecordCall.Default());
    }

    [Fact]
    public void Defaults_NoClashes()
    {
        var map = ShortcutActions.All.ToDictionary(a => a, a => a.Default());
        Assert.Empty(ShortcutActions.Clashes(map));
    }

    [Fact]
    public void Binding_DefaultThenOffThenCustom()
    {
        var prefs = new PrefsStore(Path.Combine(Path.GetTempPath(), "jc-sc-" + Guid.NewGuid().ToString("N"), "p.json"));
        Assert.Equal(ShortcutAction.OpenChat.Default(), ShortcutAction.OpenChat.Binding(prefs));
        ShortcutAction.OpenChat.SetBinding(prefs, null);
        Assert.Null(ShortcutAction.OpenChat.Binding(prefs));
        ShortcutAction.OpenChat.SetBinding(prefs, Shortcut.Parse("ctrl+shift+j"));
        Assert.Equal("ctrl+shift+j", ShortcutAction.OpenChat.Binding(prefs)!.Value.ToPrefString());
        Assert.Equal("shortcut.openChat", ShortcutAction.OpenChat.PrefKey());
    }

    [Fact]
    public void HoldKeys_Vks()
    {
        Assert.Equal(0xA5u, HoldKeys.Vk("RightAlt"));
        Assert.Equal(0xA3u, HoldKeys.Vk("RightCtrl"));
        Assert.Equal(0x87u, HoldKeys.Vk("F24"));
        Assert.Null(HoldKeys.Vk("F12"));
        Assert.Null(HoldKeys.Vk("A"));
        Assert.Equal(14, HoldKeys.Choices.Count);
    }

    [Fact]
    public void HoldKeys_TalkMustDifferFromFlow()
    {
        Assert.NotNull(HoldKeys.Problem("RightAlt", "RightAlt", true));
        Assert.Null(HoldKeys.Problem("RightAlt", "RightAlt", false));
        Assert.Null(HoldKeys.Problem("F13", "RightAlt", true));
    }

    [Fact]
    public void SessionCursor_WrapsBothWays()
    {
        var list = new[] { "a", "b", "c" }.Select(k => AgentSession.FromJson(new JsonObject { ["key"] = k })).ToList();
        var c = new SessionCursor();
        Assert.Equal("a", c.Move(list, 1)!.Key);
        Assert.Equal("b", c.Move(list, 1)!.Key);
        Assert.Equal("a", c.Move(list, -1)!.Key);
        Assert.Equal("c", c.Move(list, -1)!.Key);
        Assert.Equal("a", c.Move(list, 1)!.Key);
    }
}

public class SoundEventTests
{
    private sealed class FakeOut : ISoundOutput
    {
        public List<(string, double)> Played { get; } = new();
        public void Play(string path, double volume) => Played.Add((path, volume));
    }

    [Fact]
    public void SoundOverride_WinsOverSystem()
    {
        var path = Path.Combine(@"C:\Users\p\AppData\Roaming\Jarvis\Sounds", "finished.mp3");
        Assert.Equal(path, SoundFiles.Resolve(SoundEvent.Finished, @"C:\Users\p\AppData\Roaming\Jarvis\Sounds", p => p == path, @"C:\Windows"));
    }

    [Fact]
    public void Resolve_FallsBackToSystemWav()
    {
        var sys = Path.Combine(@"C:\Windows", "Media", "Windows Critical Stop.wav");
        Assert.Equal(sys, SoundFiles.Resolve(SoundEvent.Failed, "nope", p => p == sys, @"C:\Windows"));
        Assert.Null(SoundFiles.Resolve(SoundEvent.Failed, "nope", _ => false, @"C:\Windows"));
    }

    [Fact]
    public void FileStems() => Assert.Equal(new[] { "needs-you", "finished", "failed", "started", "decided" },
        Enum.GetValues<SoundEvent>().Select(e => e.FileStem()));

    private static (SoundCenter, FakeOut, PresentationGate, PrefsStore) Center()
    {
        var o = new FakeOut();
        var prefs = new PrefsStore(Path.Combine(Path.GetTempPath(), "jc-snd-" + Guid.NewGuid().ToString("N"), "p.json"));
        var gate = new PresentationGate(new FakeProbe(), new ManualTime());
        return (new SoundCenter(o, prefs, gate, "dir", _ => true), o, gate, prefs);
    }

    [Fact]
    public void Sounds_SilentWhileGameMode()
    {
        var (c, o, gate, _) = Center();
        gate.SetGameMode(new GameMode(true, "fullscreen", false));
        Assert.False(c.Play(SoundEvent.NeedsYou));
        Assert.Empty(o.Played);
        gate.SetGameMode(GameMode.Off);
        Assert.True(c.Play(SoundEvent.NeedsYou));
        Assert.Single(o.Played);
    }

    [Fact]
    public void Sounds_OffOrMuted_Silent_VolumeFromPrefs()
    {
        var (c, o, _, prefs) = Center();
        prefs.Set(PrefKeys.SoundVolume, 0.3);
        Assert.True(c.Play(SoundEvent.Finished));
        Assert.Equal(0.3, o.Played[0].Item2);
        c.Muted = true;
        Assert.False(c.Play(SoundEvent.Finished));
        c.Muted = false;
        prefs.Set(PrefKeys.SoundOn, false);
        Assert.False(c.Play(SoundEvent.Finished));
    }
}

public class TerminalTargetTests
{
    [Fact] public void PickExe_SessionsOwnFirst() => Assert.Equal("Code.exe", TerminalTarget.PickExe(new("vscode", "Code.exe", 0, ""), new HashSet<string> { "WindowsTerminal.exe", "Code.exe" }));
    [Fact] public void PickExe_FallsBackToKnown() => Assert.Equal("WindowsTerminal.exe", TerminalTarget.PickExe(new("", "", 0, ""), new HashSet<string> { "WindowsTerminal.exe" }));
    [Fact] public void PickExe_TermProgramMapsToExe() => Assert.Equal("Cursor.exe", TerminalTarget.PickExe(new("cursor", "", 0, ""), new HashSet<string> { "WindowsTerminal.exe", "Cursor.exe" }));
    [Fact] public void PickExe_CaseInsensitive() => Assert.Equal("windowsterminal.exe", TerminalTarget.PickExe(new("", "WindowsTerminal.exe", 0, ""), new HashSet<string> { "windowsterminal.exe" }));
    [Fact] public void PickExe_NothingRunning_Null() => Assert.Null(TerminalTarget.PickExe(new("", "", 0, ""), new HashSet<string> { "notepad.exe" }));
}

public class TrayMenuTests
{
    [Fact]
    public async Task TrayRepair_SendsTrayAction()
    {
        var link = new FakeLink();
        var state = new AppState(link, new ManualTime());
        await TrayMenu.RunLinkAction(TrayCommand.Repair, state)!;
        await TrayMenu.RunLinkAction(TrayCommand.Logs, state)!;
        await TrayMenu.RunLinkAction(TrayCommand.Restart, state)!;
        Assert.Equal(new[] { "repair", "logs", "restart" }, link.SentOfType("tray").Select(m => (string)m["action"]!));
        Assert.Null(TrayMenu.RunLinkAction(TrayCommand.Settings, state));
    }

    [Fact]
    public void Menu_HasStatusRosterAndActions()
    {
        var roster = new Roster("jarvis.example", true, new[] { new RosterRow("iPhone", "online", true, false, "iphone", null) });
        var items = TrayMenu.Build(roster, true, false, false);
        Assert.Equal("Connected to jarvis.example", items[0].Label);
        Assert.Contains(items, i => i.Label == "iPhone" && i.Online);
        foreach (var label in new[] { "Holo Drop…", "Weekly recap", "Settings", "Re-pair", "Logs", "Restart Jarvis service", "Quit" })
            Assert.Contains(items, i => i.Label == label);
    }

    [Fact]
    public void Menu_Disconnected_DisablesServerItems()
    {
        var items = TrayMenu.Build(null, false, false, false);
        Assert.Equal("Jarvis isn't running on this PC", items[0].Label);
        Assert.False(items.First(i => i.Command == TrayCommand.HoloDrop).Enabled);
        Assert.True(items.First(i => i.Command == TrayCommand.Quit).Enabled);
    }

    [Fact] public void RecapUrl() => Assert.Equal("http://127.0.0.1:8765/api/coding/agents/recap?days=7&tz=-480", Recap.Url("http://127.0.0.1:8765", -480)!.ToString());
}
