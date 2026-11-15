using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Screen;

/// The PC's Command Center controls (Win32/WinRT adapter in the app). A returned string is a
/// problem to show the viewer; null is success.
public interface IPcControls
{
    PcSnapshot Snapshot();
    IReadOnlyList<PcApp> Apps();
    byte[]? IconPng(PcApp app, int side);
    IReadOnlyList<PcWindow> Windows(int pid);
    bool CanNewWindow(int pid);

    string? SetWifi(bool on);
    string? SetBluetooth(bool on);
    string? SetDark(bool on);
    void SetVolume(int v);
    void SetMute(bool on);
    string? SetBrightness(double v);
    void Media(string key);

    string? ActivateApp(int pid);
    string? RaiseWindow(int pid, long hwnd);
    string? AppAction(string action, int pid);

    string? SwitchDisplay(int id);
    void Lock();
    void QuickSettings();
    void TaskView();
    void ShowDesktop();
    void Sleep();
    Task<string?> SetKeepAwake(bool on);
}

/// One viewer's `{"t":"cc",...}` messages (port of MacControls.run): do the action, report a
/// problem as `cc_error`, let it settle, then always a fresh `cc_state`; `cc_apps` (+ each new
/// icon once per viewer) when apps may have changed; `cc_windows` after `window`/`app_new_window`.
public sealed class CcCommands
{
    private readonly IPcControls _pc;
    private readonly Action<JsonObject> _reply;
    private readonly Action<TimeSpan> _settle;
    private readonly HashSet<string> _sentIcons = new();

    public CcCommands(IPcControls pc, Action<JsonObject> reply, Action<TimeSpan> settle)
    {
        _pc = pc;
        _reply = reply;
        _settle = settle;
    }

    public static TimeSpan Settle(string action) => action switch
    {
        "app" or "window" or "app_hide" or "app_show_all" => TimeSpan.FromMilliseconds(250),
        "app_quit" or "app_new_window" => TimeSpan.FromMilliseconds(600),
        _ => TimeSpan.FromMilliseconds(400),
    };

    public async Task HandleAsync(JsonObject m)
    {
        var action = J.S(m["do"]);
        var on = J.B(m["on"]);
        string? problem = null;
        var appsChanged = action == "state";
        int? windowsOf = null;
        var pid = J.I(m["pid"]);
        switch (action)
        {
            case "windows":
                _reply(CcPayloads.Windows(pid, _pc.Windows(pid), _pc.CanNewWindow(pid)));
                return;
            case "state":
                break;
            case "wifi": problem = _pc.SetWifi(on); break;
            case "bluetooth": problem = _pc.SetBluetooth(on); break;
            case "dark": problem = _pc.SetDark(on); break;
            case "volume": _pc.SetVolume(Math.Clamp(J.I(m["value"]), 0, 100)); break;
            case "mute": _pc.SetMute(on); break;
            case "brightness": problem = _pc.SetBrightness(Math.Clamp(J.D(m["value"]) ?? 0.5, 0, 1)); break;
            case "media":
                _pc.Media(J.S(m["key"]) switch { "next" => "next", "previous" => "previous", _ => "play" });
                break;
            case "app":
                problem = _pc.ActivateApp(pid);
                appsChanged = true;
                break;
            case "window":
                problem = _pc.RaiseWindow(pid, J.L(m["id"]));
                appsChanged = true;
                windowsOf = pid;
                break;
            case "app_new_window" or "app_show_all" or "app_hide" or "app_quit":
                problem = _pc.AppAction(action, pid);
                appsChanged = true;
                if (action == "app_new_window") windowsOf = pid;
                break;
            case "display": problem = _pc.SwitchDisplay(J.I(m["id"])); break;
            case "lock": _pc.Lock(); break;
            case "control_center": _pc.QuickSettings(); break;
            case "mission_control": _pc.TaskView(); break;
            case "show_desktop": _pc.ShowDesktop(); break;
            case "keep_awake": problem = await _pc.SetKeepAwake(on).ConfigureAwait(false); break;
            case "sleep":
                // The viewer hears back before the PC goes to sleep.
                _reply(CcState.Build(_pc.Snapshot()));
                _settle(TimeSpan.FromSeconds(1));
                _pc.Sleep();
                return;
            default:
                problem = $"The PC app doesn't know “{action}” yet: update Jarvis on the PC.";
                break;
        }
        if (problem != null) _reply(new JsonObject { ["t"] = "cc_error", ["do"] = action, ["error"] = problem });
        if (action != "state") _settle(Settle(action));
        _reply(CcState.Build(_pc.Snapshot()));
        if (appsChanged) SendApps();
        if (windowsOf is { } w) _reply(CcPayloads.Windows(w, _pc.Windows(w), _pc.CanNewWindow(w)));
    }

    private void SendApps()
    {
        var apps = _pc.Apps();
        _reply(CcPayloads.Apps(apps));
        foreach (var app in apps)
        {
            if (_sentIcons.Contains(app.Bundle)) continue;
            if (_pc.IconPng(app, 96) is not { } png) continue;
            _sentIcons.Add(app.Bundle);
            _reply(CcPayloads.Icon(app.Bundle, png));
        }
    }
}
