using System.IO;
using Jarvis.Core.Admin;
using Jarvis.Core.GlassesCamera;
using Microsoft.Win32;
using Windows.Devices.Enumeration;

namespace Jarvis.GlassesCamera;

/// Installs, removes and checks the Jarvis Glasses camera (Settings → Glasses camera). The admin
/// part is one script (glasses-camera.ps1, next to the camera's files in the app folder) run through
/// the existing phone Face ID + UAC path (AdminRunner): it copies the camera into Program Files,
/// registers its media source, makes the frame file and creates the virtual camera with system
/// lifetime (it survives reboots). The admin launch doesn't report back, so the script leaves its
/// result in install-result.json, which this waits for.
public sealed class GlassesCamInstaller
{
    /// How long the script may take after his Face ID (it waits on Windows' Yes first).
    public static readonly TimeSpan ScriptWait = TimeSpan.FromMinutes(3);

    private readonly AdminRunner _admin;
    private readonly Action<string> _log;
    private string? _working;

    public GlassesCamInstaller(AdminRunner admin, Action<string> log)
    {
        _admin = admin;
        _log = log;
    }

    public GlassesCamInstallState State { get; private set; } = new GlassesCamInstallState.NotInstalled();
    /// The admin card's last line ("Approved on your iPhone…", "Denied…"), for Settings.
    public string? Note { get; private set; }
    public event Action? Changed;

    /// The camera's files inside this build of the app (package.ps1 puts them there).
    public static string AppCameraDir => Path.Combine(AppContext.BaseDirectory, "GlassesCamera");

    /// Cheap enough for the service's 10-second look: the media source registered and the frame file made.
    public static bool Installed() => SourceRegistered() && File.Exists(GlassesCamSpec.FrameFilePath);

    public static bool SourceRegistered()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SOFTWARE\Classes\CLSID\{{{GlassesCamSpec.SourceClsid}}}\InprocServer32");
            return key?.GetValue(null) is string path && File.Exists(path);
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    /// Whether Windows lists "Jarvis Glasses" among its cameras (null: couldn't look).
    public static async Task<bool?> CameraListedAsync()
    {
        try
        {
            var all = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
            return all.Any(d => d.Name == GlassesCamSpec.Name);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            return null;
        }
    }

    public static GlassesCamInstallResult? LastResult()
    {
        try { return File.Exists(GlassesCamSpec.InstallResultPath) ? GlassesCamInstallResult.Parse(File.ReadAllText(GlassesCamSpec.InstallResultPath)) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    public async Task RefreshAsync()
    {
        var facts = new GlassesCamInstallFacts(SourceRegistered(), File.Exists(GlassesCamSpec.FrameFilePath), await CameraListedAsync(), LastResult(), _working);
        State = GlassesCamInstall.State(facts);
        Changed?.Invoke();
    }

    public Task InstallAsync() => RunAsync(remove: false);

    public Task RemoveAsync() => RunAsync(remove: true);

    private async Task RunAsync(bool remove)
    {
        if (_working != null) return;
        var dir = AppCameraDir;
        if (!File.Exists(Path.Combine(dir, GlassesCamInstall.ScriptName)))
        {
            Note = "The camera is missing from this build of Jarvis.";
            await RefreshAsync();
            return;
        }
        _working = remove ? "Removing…" : "Installing…";
        Note = AdminRunner.AskingLine;
        await RefreshAsync();
        try
        {
            var before = LastResult()?.At ?? DateTimeOffset.MinValue;
            var result = await _admin.RunAsync(GlassesCamInstall.Command(dir, remove),
                remove ? "Remove the Jarvis Glasses camera" : "Install the Jarvis Glasses camera");
            Note = result.Message;
            _log($"glasses camera {(remove ? "remove" : "install")}: {result.Status} {result.Error}");
            if (result.Kind != AdminStatus.Approved) return;
            // The script runs once he clicks Yes on Windows' prompt: wait for what it wrote.
            var until = DateTimeOffset.UtcNow + ScriptWait;
            while (DateTimeOffset.UtcNow < until)
            {
                await Task.Delay(TimeSpan.FromSeconds(1));
                if (LastResult() is { } r && r.At > before)
                {
                    Note = r.Ok ? (remove ? "Removed." : "Installed. Pick “Jarvis Glasses” as the camera in any app.") : null;
                    _log($"glasses camera {r.Action}: {(r.Ok ? "ok" : $"failed at {r.Step} hr={r.HResult} {r.Error}")}");
                    return;
                }
            }
            Note = "Windows' prompt wasn't answered, so nothing changed.";
        }
        finally
        {
            _working = null;
            await RefreshAsync();
        }
    }
}
