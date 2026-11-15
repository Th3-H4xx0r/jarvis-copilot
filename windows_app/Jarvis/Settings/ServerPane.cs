using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Jarvis.Settings;

/// The server's own Settings sections in one WebView2, created when a server pane first opens
/// and disposed with the Settings window: no WebView stays alive outside Settings.
public sealed class ServerPane : IDisposable
{
    private static int _live;
    private readonly WebView2 _web;
    private readonly Task _ready;
    private Uri? _pending;

    /// How many WebViews exist right now (0 whenever Settings is closed).
    public static int LiveWebViews => _live;

    public static string UserDataFolder => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis", "WebView2");

    public ServerPane()
    {
        Interlocked.Increment(ref _live);
        _web = new WebView2
        {
            DefaultBackgroundColor = System.Drawing.Color.Transparent,
            MinHeight = 560,
        };
        _ready = InitAsync();
    }

    public FrameworkElement View => _web;

    private async Task InitAsync()
    {
        var env = await CoreWebView2Environment.CreateAsync(null, UserDataFolder);
        await _web.EnsureCoreWebView2Async(env);
        // The web Settings checks for the native shell's bridge object.
        await _web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("window.JarvisCopilotMobile = window.JarvisCopilotMobile || {};");
        _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
        _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
        if (_pending != null) _web.CoreWebView2.Navigate(_pending.ToString());
    }

    public void Navigate(Uri url)
    {
        _pending = url;
        if (_ready.IsCompletedSuccessfully) _web.CoreWebView2.Navigate(url.ToString());
    }

    public void Dispose()
    {
        _web.Dispose();
        Interlocked.Decrement(ref _live);
    }
}
