namespace Jarvis.Core.Service;

/// Runs a program with no window and returns its exit code and stdout.
public delegate Task<(int Code, string Out)> HiddenRunner(string exe, IReadOnlyList<string> args);

public enum JcClientState { Missing, Running, Stopped, Starting, Unknown }

/// The app owns jc-client (the background service): it starts it when the app opens and whenever
/// the link is down, and the tray's Restart / Stop drive it. jc-client itself runs from the
/// per-user scheduled task `\JarvisCopilot\jc-client` (installers/install-windows.ps1), hidden
/// behind `conhost --headless`, so it keeps running if the app quits and restarts on a crash.
/// A disabled task means "stopped on purpose" (`jc-client stop`): left alone. Except before it's
/// paired: the installer leaves the task disabled until then, and the app's "Pair with your
/// iPhone" screen needs jc-client running (it makes the QR), so an unpaired one is started.
public sealed class JcClientControl
{
    public const string TaskName = @"\JarvisCopilot\jc-client";

    private readonly string _exe;
    private readonly HiddenRunner _run;
    /// `jc-client status` already asked during this stopped spell (it starts Python: not every minute).
    private bool _askedWhileStopped;

    public JcClientControl(string localAppData, HiddenRunner run)
    {
        _exe = Path.Combine(localAppData, "Programs", "jc-client", ".venv", "Scripts", "jc-client.exe");
        _run = run;
    }

    public string Exe => _exe;

    /// The task's state from `schtasks /Query /FO LIST` ("Status: Running" / "Ready" / "Disabled").
    public static JcClientState ParseQuery(int code, string output)
    {
        if (code != 0) return JcClientState.Missing;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("Status:", StringComparison.OrdinalIgnoreCase)) continue;
            var v = line["Status:".Length..].Trim();
            if (v.Equals("Running", StringComparison.OrdinalIgnoreCase)) return JcClientState.Running;
            if (v.Equals("Disabled", StringComparison.OrdinalIgnoreCase)) return JcClientState.Stopped;
            return JcClientState.Unknown;   // Ready, Queued, ...: not running
        }
        return JcClientState.Unknown;
    }

    public async Task<JcClientState> QueryAsync()
    {
        if (!File.Exists(_exe)) return JcClientState.Missing;
        var (code, output) = await _run("schtasks.exe", new[] { "/Query", "/TN", TaskName, "/FO", "LIST" });
        return ParseQuery(code, output);
    }

    /// `jc-client status`'s "paired: yes/no" line; null when it didn't answer.
    public static bool? ParsePaired(int code, string output)
    {
        if (code != 0) return null;
        var m = System.Text.RegularExpressions.Regex.Match(output, @"paired:\s+(yes|no)\b",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value.Equals("yes", StringComparison.OrdinalIgnoreCase) : null;
    }

    /// Starts jc-client unless it's running, stopped on purpose, or not installed. A stopped one
    /// that isn't paired yet is started (enabled again) so the pair screen can work.
    public async Task<JcClientState> EnsureRunningAsync()
    {
        var state = await QueryAsync();
        if (state == JcClientState.Stopped)
        {
            if (_askedWhileStopped) return state;
            _askedWhileStopped = true;
            var (code, output) = await _run(_exe, new[] { "status" });
            if (ParsePaired(code, output) != false) return state;
            await RestartAsync();
            return JcClientState.Starting;
        }
        _askedWhileStopped = false;
        if (state != JcClientState.Unknown) return state;
        await _run("schtasks.exe", new[] { "/Run", "/TN", TaskName });
        return JcClientState.Starting;
    }

    /// `jc-client restart`: enables the task again (after a Stop) and starts it fresh.
    public Task RestartAsync() => _run(_exe, new[] { "restart" });

    /// `jc-client stop`: ends it and disables the task so its 5-minute watch doesn't bring it back.
    public Task StopAsync() => _run(_exe, new[] { "stop" });
}

/// The real runner: no console window (CreateNoWindow), stdout captured, never throws.
public static class HiddenProcess
{
    public static async Task<(int Code, string Out)> RunAsync(string exe, IReadOnlyList<string> args)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = System.Diagnostics.Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEndAsync();
            _ = p.StandardError.ReadToEndAsync();   // drained so a chatty stderr can't block it
            await p.WaitForExitAsync();
            return (p.ExitCode, await output);
        }
        catch (Exception)
        {
            return (-1, "");
        }
    }
}
