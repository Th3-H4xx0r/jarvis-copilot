using Jarvis.Core.Link;
using Jarvis.Core.Screen;

namespace Jarvis.Tests.Screen;

public sealed class FakePc : IPcControls
{
    public readonly List<string> Calls = new();
    public string? BrightnessProblem;
    public List<PcApp> AppList = new() { new PcApp(42, "Chrome", "chrome.exe", true, false, @"C:\chrome.exe"), new PcApp(7, "Code", "code.exe", false, false, @"C:\code.exe") };

    public PcSnapshot Snapshot() => new(true, "Home", true, false, 40, false, null, false, null, new[] { new PcDisplay(1, "Main", true, 2560, 1440) }, 1, false);
    public IReadOnlyList<PcApp> Apps() => AppList;
    public byte[]? IconPng(PcApp app, int side) => new byte[] { 1, 2, 3 };
    public IReadOnlyList<PcWindow> Windows(int pid) => Enumerable.Range(0, 35).Select(i => new PcWindow(1000 + i, new string('t', 150), false, i == 0)).ToList();
    public bool CanNewWindow(int pid) => true;
    public string? SetWifi(bool on) { Calls.Add($"SetWifi({on})"); return null; }
    public string? SetBluetooth(bool on) { Calls.Add($"SetBluetooth({on})"); return null; }
    public string? SetDark(bool on) { Calls.Add($"SetDark({on})"); return null; }
    public void SetVolume(int v) => Calls.Add($"SetVolume({v})");
    public void SetMute(bool on) => Calls.Add($"SetMute({on})");
    public string? SetBrightness(double v) { Calls.Add(FormattableString.Invariant($"SetBrightness({v})")); return BrightnessProblem; }
    public void Media(string key) => Calls.Add($"Media({key})");
    public string? ActivateApp(int pid) { Calls.Add($"ActivateApp({pid})"); return null; }
    public string? RaiseWindow(int pid, long hwnd) { Calls.Add($"RaiseWindow({pid},{hwnd})"); return null; }
    public string? AppAction(string action, int pid) { Calls.Add($"AppAction({action},{pid})"); return null; }
    public string? SwitchDisplay(int id) { Calls.Add($"SwitchDisplay({id})"); return null; }
    public void Lock() => Calls.Add("Lock()");
    public void QuickSettings() => Calls.Add("QuickSettings()");
    public void TaskView() => Calls.Add("TaskView()");
    public void ShowDesktop() => Calls.Add("ShowDesktop()");
    public void Sleep() => Calls.Add("Sleep()");
    public Task<string?> SetKeepAwake(bool on) { Calls.Add($"SetKeepAwake({on})"); return Task.FromResult<string?>(null); }
}

public class CcCommandsTests
{
    private readonly FakePc _pc = new();
    private readonly List<JsonObject> _replies = new();
    private readonly List<TimeSpan> _settles = new();
    private readonly CcCommands _cc;

    public CcCommandsTests() => _cc = new CcCommands(_pc, _replies.Add, _settles.Add);

    private IEnumerable<string> Kinds => _replies.Select(r => J.S(r["t"]));

    [Theory]
    [InlineData("{\"t\":\"cc\",\"do\":\"wifi\",\"on\":false}", "SetWifi(False)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"bluetooth\",\"on\":true}", "SetBluetooth(True)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"dark\",\"on\":true}", "SetDark(True)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"volume\",\"value\":150}", "SetVolume(100)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"mute\",\"on\":true}", "SetMute(True)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"brightness\",\"value\":0.3}", "SetBrightness(0.3)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"media\",\"key\":\"next\"}", "Media(next)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"app\",\"pid\":42}", "ActivateApp(42)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"window\",\"pid\":42,\"id\":1234}", "RaiseWindow(42,1234)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"app_quit\",\"pid\":42}", "AppAction(app_quit,42)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"display\",\"id\":2}", "SwitchDisplay(2)")]
    [InlineData("{\"t\":\"cc\",\"do\":\"lock\"}", "Lock()")]
    [InlineData("{\"t\":\"cc\",\"do\":\"control_center\"}", "QuickSettings()")]
    [InlineData("{\"t\":\"cc\",\"do\":\"mission_control\"}", "TaskView()")]
    [InlineData("{\"t\":\"cc\",\"do\":\"show_desktop\"}", "ShowDesktop()")]
    [InlineData("{\"t\":\"cc\",\"do\":\"sleep\"}", "Sleep()")]
    [InlineData("{\"t\":\"cc\",\"do\":\"keep_awake\",\"on\":true}", "SetKeepAwake(True)")]
    public async Task Dispatch_CallsControlThenRepliesState(string msg, string call)
    {
        await _cc.HandleAsync(J.Parse(msg));
        Assert.Equal(call, _pc.Calls[0]);
        Assert.Single(_pc.Calls);
        Assert.Contains("cc_state", Kinds);
        var action = J.S(J.Parse(msg)["do"]);
        if (action is "app" or "window" or "app_quit") Assert.Contains("cc_apps", Kinds);
        else Assert.DoesNotContain("cc_apps", Kinds);
        if (action == "window") Assert.Equal("cc_windows", Kinds.Last());
        else Assert.Equal("cc_state", action is "app" or "app_quit" ? Kinds.First(k => k == "cc_state") : Kinds.Last());
        Assert.DoesNotContain("cc_error", Kinds);
    }

    [Fact]
    public async Task Dispatch_MediaDefaultsToPlay()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"media\"}"));
        Assert.Equal("Media(play)", _pc.Calls[0]);
    }

    [Theory]
    [InlineData("app", 250)]
    [InlineData("window", 250)]
    [InlineData("app_hide", 250)]
    [InlineData("app_show_all", 250)]
    [InlineData("app_quit", 600)]
    [InlineData("app_new_window", 600)]
    [InlineData("wifi", 400)]
    public async Task Dispatch_Settles(string action, int ms)
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"" + action + "\",\"pid\":42}"));
        Assert.Equal(TimeSpan.FromMilliseconds(ms), _settles[0]);
    }

    [Fact]
    public async Task Dispatch_Sleep_StateBeforeSleeping()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"sleep\"}"));
        Assert.Equal(new[] { "cc_state" }, Kinds);
        Assert.Equal(TimeSpan.FromSeconds(1), _settles.Last());
        Assert.Equal("Sleep()", _pc.Calls.Single());
    }

    [Fact]
    public async Task Dispatch_State_SendsStateAppsAndNewIconsOnce()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"state\"}"));
        Assert.Equal(new[] { "cc_state", "cc_apps", "cc_icon", "cc_icon" }, Kinds);
        Assert.Empty(_settles);
        _replies.Clear();
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"state\"}"));
        Assert.Equal(new[] { "cc_state", "cc_apps" }, Kinds);
        _pc.AppList.Add(new PcApp(9, "Notepad", "notepad.exe", false, false, @"C:\notepad.exe"));
        _replies.Clear();
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"state\"}"));
        Assert.Equal("notepad.exe", J.S(_replies.Single(r => J.S(r["t"]) == "cc_icon")["bundle"]));
    }

    [Fact]
    public async Task Dispatch_Windows_OnlyWindowsList()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"windows\",\"pid\":42}"));
        var r = Assert.Single(_replies);
        Assert.Equal("cc_windows", J.S(r["t"]));
        Assert.True(J.B(r["ax"]));
        Assert.True(r["windows"]!.AsArray().Count <= 30);
        Assert.All(r["windows"]!.AsArray(), w => Assert.True(J.S(w!["title"]).Length <= 120));
        Assert.Empty(_pc.Calls);
    }

    [Fact]
    public async Task Dispatch_Unknown_CcError()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"stage\",\"on\":true}"));
        Assert.Equal("{\"do\":\"stage\",\"error\":\"The PC app doesn't know “stage” yet: update Jarvis on the PC.\",\"t\":\"cc_error\"}", J.SortedJson(_replies[0]));
        Assert.Equal("cc_state", J.S(_replies[1]["t"]));
    }

    [Fact]
    public async Task Dispatch_ProblemString_SendsCcError()
    {
        _pc.BrightnessProblem = "This display's brightness can't be set from here.";
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"brightness\",\"value\":2}"));
        Assert.Equal("SetBrightness(1)", _pc.Calls[0]);
        Assert.Equal("{\"do\":\"brightness\",\"error\":\"This display's brightness can't be set from here.\",\"t\":\"cc_error\"}", J.SortedJson(_replies[0]));
        Assert.Equal("cc_state", J.S(_replies.Last()["t"]));
    }

    [Fact]
    public async Task Dispatch_AppNewWindow_SendsWindowsAfterApps()
    {
        await _cc.HandleAsync(J.Parse("{\"t\":\"cc\",\"do\":\"app_new_window\",\"pid\":42}"));
        Assert.Equal(new[] { "cc_state", "cc_apps", "cc_icon", "cc_icon", "cc_windows" }, Kinds);
    }
}
