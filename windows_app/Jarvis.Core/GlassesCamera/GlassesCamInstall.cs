using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jarvis.Core.GlassesCamera;

/// What the camera is, for Settings → Glasses camera.
public abstract record GlassesCamInstallState
{
    public sealed record NotInstalled : GlassesCamInstallState;
    public sealed record Installed : GlassesCamInstallState;
    public sealed record Working(string What) : GlassesCamInstallState;
    public sealed record Failed(string Why) : GlassesCamInstallState;

    public string Text => this switch
    {
        Installed => "Installed",
        Working w => w.What,
        Failed f => f.Why,
        _ => "Not installed",
    };
}

/// What the admin script (glasses-camera.ps1) wrote when it last ran: install-result.json.
/// `Step`: copy, register, frames, create, start or remove; `HResult`: Windows' code, if any.
public sealed record GlassesCamInstallResult(bool Ok, string Action, string Step, int? HResult, string? Error, DateTimeOffset At)
{
    public static GlassesCamInstallResult? Parse(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o) return null;
            static string S(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
            int? hr = o["hr"] is JsonValue h && h.TryGetValue<long>(out var l) ? unchecked((int)l) : null;
            var at = DateTimeOffset.TryParse(S(o["at"]), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var t) ? t : DateTimeOffset.MinValue;
            var ok = o["ok"] is JsonValue okv && okv.TryGetValue<bool>(out var b) && b;
            var error = S(o["error"]);
            return new GlassesCamInstallResult(ok, S(o["action"]), S(o["step"]), hr, error.Length > 0 ? error : null, at);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// The facts Settings looks at: the media source registered (HKLM CLSID), the frame file made,
/// "Jarvis Glasses" in Windows' camera list (null: couldn't look), the last admin result, and
/// what's running now (null: nothing).
public sealed record GlassesCamInstallFacts(bool SourceRegistered, bool FrameFileReady, bool? CameraListed,
    GlassesCamInstallResult? LastResult, string? Working);

public static class GlassesCamInstall
{
    public const string ScriptName = "glasses-camera.ps1";

    public static GlassesCamInstallState State(GlassesCamInstallFacts f)
    {
        if (f.Working is { } w) return new GlassesCamInstallState.Working(w);
        var listed = f.CameraListed ?? (f.SourceRegistered && f.FrameFileReady);
        if (f.SourceRegistered && f.FrameFileReady && listed) return new GlassesCamInstallState.Installed();
        if (f.LastResult is { Ok: false } failed) return new GlassesCamInstallState.Failed(Explain(failed));
        if (!f.SourceRegistered && !f.FrameFileReady && !listed) return new GlassesCamInstallState.NotInstalled();
        return new GlassesCamInstallState.Failed("The camera is only half installed. Reinstall it.");
    }

    /// Why an install or remove failed, in his words and with what to do (never Windows' raw code).
    public static string Explain(GlassesCamInstallResult r)
    {
        if (r.Error == "unsupported") return "Virtual cameras need Windows 11 (22H2 or later); this PC's Windows doesn't have them.";
        switch (r.Step)
        {
            case "copy":
                return "Windows couldn't copy the camera's files into Program Files (something may have them open). Close apps using a camera, then Reinstall.";
            case "register":
                return "Windows couldn't register the camera's code. Reinstall; if it fails again, restart the PC first.";
            case "frames":
                return "Couldn't set up the file the camera reads the video from. Reinstall.";
        }
        var what = r.Action == "remove" ? "remove" : "start";
        switch (unchecked((uint)(r.HResult ?? 0)))
        {
            case 0x80070005:
                return "Windows' camera service (Frame Server) wasn't allowed to open the camera's files. Reinstall: it puts them in Program Files, where the camera service can read them.";
            case 0x80040154:
                return "Windows doesn't know the camera's code (it isn't registered). Reinstall the camera.";
            case 0x80070002 or 0x80070003 or 0x8007007E:
                return "The camera's files are missing. Reinstall the camera.";
            case >= 0x80008080 and <= 0x800080AF:
                return "The camera needs .NET 8 installed for all users on this PC. Install the .NET 8 Runtime (x64), then Reinstall.";
        }
        return r.Action == "remove"
            ? "Windows couldn't remove the camera. Restart the PC and try Remove again."
            : $"Windows couldn't {what} the camera. Restart the PC, then Reinstall.";
    }

    /// The admin command (run elevated after Face ID and Windows' Yes): the script next to the
    /// camera's files in the app folder, which copies them to Program Files and sets it all up.
    public static string Command(string appCameraDir, bool remove)
    {
        var dir = appCameraDir.TrimEnd('\\');
        return $"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{dir}\\{ScriptName}\" -From \"{dir}\"" + (remove ? " -Remove" : "");
    }
}
