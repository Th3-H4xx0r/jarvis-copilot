namespace Jarvis.Core.GlassesCamera;

/// The "Jarvis Glasses" camera on this PC (the Mac's GlassesCameraSpec): what the Jarvis app,
/// the camera's media source (JarvisGlassesCam, loaded by Windows' camera service) and the
/// installer must agree on. The picture's path: the iPhone sends the glasses' live video over
/// WebRTC → the app (GlassesCameraService) draws each frame into a 720×1280 BGRA frame in the
/// frame file (GlassesCamFrameFile) → the media source hands it to Teams, Zoom, Discord or the
/// browser. With no fresh frame the source draws the "Glasses not streaming" card itself.
public static class GlassesCamSpec
{
    public const string Name = "Jarvis Glasses";

    /// The media source's COM class. Fixed, so apps remember the camera across reinstalls.
    public const string SourceClsid = "c34843a9-6485-4a3b-b3f0-3fbc91fd3ced";

    /// The glasses' live format (portrait), and the same letterboxed into landscape for apps
    /// that only take landscape. Index = the format's place in the camera's list.
    public static readonly (int W, int H) Portrait = (720, 1280);
    public static readonly (int W, int H) Landscape = (1280, 720);
    public static readonly IReadOnlyList<(int W, int H)> Formats = new[] { Portrait, Landscape };
    public const int Fps = 30;

    /// No new frame for this long: the source shows the card (a short network stall freezes the
    /// picture rather than flashing the card).
    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(2.0);

    /// The app keeps asking for video this long after the last app stopped using the camera, so
    /// switching cameras or rejoining a call doesn't tear the connection down.
    public static readonly TimeSpan Linger = TimeSpan.FromSeconds(15);

    /// The source writes a heartbeat each second while a stream runs; older than this, the count
    /// it left is from a camera service that died, and nobody is using the camera.
    public static readonly TimeSpan BeatStaleAfter = TimeSpan.FromSeconds(5);

    /// Where the installer puts the camera's files (readable by the camera service's accounts:
    /// a folder under the user's profile isn't, and Windows then refuses with "access denied").
    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Jarvis", "GlassesCamera");

    public static string DataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Jarvis", "GlassesCamera");

    /// Made by the installer, writable by his account and the camera service.
    public static string FrameFilePath => Path.Combine(DataDir, "frames.bin");

    /// What the last install or remove did (written by the admin script).
    public static string InstallResultPath => Path.Combine(DataDir, "install-result.json");
}

/// Whether this PC should be asking the iPhone for the glasses' video right now: while an app is
/// using the camera, and a little after (GlassesCamSpec.Linger). The Mac's GlassesCameraDemand.
public sealed class GlassesCamDemand
{
    public DateTimeOffset? LastInUse { get; private set; }

    /// `clients`: apps using the camera; null when it can't be read (then ask while installed —
    /// more traffic, but the camera still works).
    public bool Wanted(bool installed, int? clients, DateTimeOffset now)
    {
        if (!installed)
        {
            LastInUse = null;
            return false;
        }
        if (clients is not { } n || n > 0)
        {
            LastInUse = now;
            return true;
        }
        return LastInUse is { } last && now - last < GlassesCamSpec.Linger;
    }
}

/// The phone's WebRTC peer, as the service sees it.
public enum GlassesCamPeerState { Connecting, Connected, Disconnected, Failed }

/// What the PC's Jarvis Glasses camera is doing, for Settings.
public enum GlassesCamPhase { NotInstalled, Idle, Offline, WaitingForPhone, Connecting, Connected, Live, Failed }

public static class GlassesCamPhases
{
    public static GlassesCamPhase Of(bool installed, bool wanted, bool online, bool asked, GlassesCamPeerState? peer,
        bool frameFresh, string? failure = null)
    {
        if (!installed) return GlassesCamPhase.NotInstalled;
        if (failure != null) return GlassesCamPhase.Failed;
        if (!wanted) return GlassesCamPhase.Idle;
        if (!online) return GlassesCamPhase.Offline;
        if (!asked) return GlassesCamPhase.Connecting;
        return peer switch
        {
            GlassesCamPeerState.Connecting => GlassesCamPhase.Connecting,
            GlassesCamPeerState.Connected => frameFresh ? GlassesCamPhase.Live : GlassesCamPhase.Connected,
            _ => GlassesCamPhase.WaitingForPhone,
        };
    }

    public static string Text(this GlassesCamPhase phase, string? failure = null) => phase switch
    {
        GlassesCamPhase.NotInstalled => "Not installed yet.",
        GlassesCamPhase.Idle => "Ready. Pick “Jarvis Glasses” as the camera in Teams, Zoom, Discord or your browser.",
        GlassesCamPhase.Offline => "An app is using the camera, but Jarvis isn't connected to your server.",
        GlassesCamPhase.WaitingForPhone =>
            "An app is using the camera. On your iPhone: Meta glasses → Watch live → Send to computer camera.",
        GlassesCamPhase.Connecting => "Connecting to your iPhone…",
        GlassesCamPhase.Connected => "Connected to your iPhone. Waiting for the glasses' video…",
        GlassesCamPhase.Live => "Showing your glasses' live video.",
        _ => failure ?? "Something went wrong with the camera.",
    };
}

/// Fitting one picture inside another: aspect kept, centred, whole and even pixels (the Mac's
/// GlassesFrameGeometry.fit).
public static class GlassesCamGeometry
{
    public static (int X, int Y, int W, int H) Fit((int W, int H) source, (int W, int H) target)
    {
        if (source.W <= 0 || source.H <= 0 || target.W < 2 || target.H < 2) return (0, 0, target.W, target.H);
        var scale = Math.Min((double)target.W / source.W, (double)target.H / source.H);
        static int Even(double v, int limit) =>
            Math.Min(limit, Math.Max(2, (int)Math.Floor(Math.Round(v, MidpointRounding.AwayFromZero) / 2) * 2));
        var w = Even(source.W * scale, target.W);
        var h = Even(source.H * scale, target.H);
        return ((target.W - w) / 2, (target.H - h) / 2, w, h);
    }
}
