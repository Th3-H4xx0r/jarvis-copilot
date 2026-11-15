using System.Diagnostics;
using System.Windows.Automation;
using Jarvis.Core.Chat;
using Jarvis.Core.Holo;
using Jarvis.Core.Platform;

namespace Jarvis.Platform;

/// The window in front: app name, exe, title and, in a browser, the page address read from its
/// address bar through UI Automation (1 s cap, so a hung app can't hold anything up). Explorer's
/// selected files through Shell.Application, selected text through UIA's TextPattern. Only ever
/// called on his key press (Ctrl+Alt+W, Ctrl+Alt+H); nothing is read otherwise.
public sealed class FrontWindowProbe : IFrontWindowProbe, IHoloFrontProbe
{
    private static readonly TimeSpan UiaTimeout = TimeSpan.FromSeconds(1);

    public FrontWindow? Front() => Capture(Native.GetForegroundWindow());

    public FrontWindow? Capture(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId) return null;
        string exe = "", app = "";
        try
        {
            var p = Process.GetProcessById((int)pid);
            exe = p.ProcessName + ".exe";
            app = AppName(p) ?? p.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException) { }
        var buf = new char[512];
        var n = Native.GetWindowText(hwnd, buf, buf.Length);
        var title = n > 0 ? new string(buf, 0, n) : "";
        var w = new FrontWindow(app, exe, (int)pid, hwnd, BrowserUrl.StripBrowserSuffix(title, exe), null);
        return BrowserUrl.BrowserExes.Contains(exe) ? w with { Url = ((IHoloFrontProbe)this).BrowserUrl(w) } : w;
    }

    private static string? AppName(Process p)
    {
        try { return p.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } d ? d : null; }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
    }

    string? IHoloFrontProbe.BrowserUrl(FrontWindow w) => WithTimeout(() =>
    {
        var root = AutomationElement.FromHandle(w.Hwnd);
        var firefox = w.Exe.Equals("firefox.exe", StringComparison.OrdinalIgnoreCase);
        Condition cond = firefox
            ? new PropertyCondition(AutomationElement.AutomationIdProperty, "urlbar-input")
            : new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                new PropertyCondition(AutomationElement.NameProperty, "Address and search bar"));
        var bar = root.FindFirst(TreeScope.Descendants, cond);
        if (bar?.TryGetCurrentPattern(ValuePattern.Pattern, out var vp) == true)
            return Core.Chat.BrowserUrl.Normalise(((ValuePattern)vp).Current.Value);
        return null;
    });

    public IReadOnlyList<string> ExplorerSelection(IntPtr hwnd)
    {
        var o = new List<string>();
        try
        {
            var type = Type.GetTypeFromProgID("Shell.Application");
            if (type == null) return o;
            dynamic shell = Activator.CreateInstance(type)!;
            foreach (dynamic win in shell.Windows())
            {
                if ((long)win.HWND != hwnd.ToInt64()) continue;
                foreach (dynamic item in win.Document.SelectedItems()) o.Add((string)item.Path);
                break;
            }
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or InvalidCastException) { }
        return o;
    }

    /// Windows has no general "front document" (the Mac's AXDocument); none.
    public string? DocumentPath(FrontWindow w) => null;

    public string? SelectedText(FrontWindow w) => WithTimeout(() =>
    {
        var focused = AutomationElement.FocusedElement;
        if (focused?.TryGetCurrentPattern(TextPattern.Pattern, out var tp) != true) return null;
        var text = string.Concat(((TextPattern)tp).GetSelection().Select(r => r.GetText(20_000)));
        return text.Trim().Length > 0 ? text : null;
    });

    private static T? WithTimeout<T>(Func<T?> f) where T : class
    {
        var task = Task.Run(() =>
        {
            try { return f(); }
            catch (Exception e) when (e is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { return null; }
        });
        return task.Wait(UiaTimeout) ? task.Result : null;
    }
}
