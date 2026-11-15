using Jarvis.Core.Gaming;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;

namespace Jarvis.Core.Sounds;

public enum SoundEvent { NeedsYou, Finished, Failed, Started, Decided }

public static class SoundEvents
{
    public static string FileStem(this SoundEvent e) => e switch
    {
        SoundEvent.NeedsYou => "needs-you",
        SoundEvent.Finished => "finished",
        SoundEvent.Failed => "failed",
        SoundEvent.Started => "started",
        _ => "decided",
    };

    public static string SystemWavName(this SoundEvent e) => e switch
    {
        SoundEvent.NeedsYou => "Windows Notify System Generic.wav",
        SoundEvent.Finished => "Windows Notify Calendar.wav",
        SoundEvent.Failed => "Windows Critical Stop.wav",
        SoundEvent.Started => "Windows Navigation Start.wav",
        _ => "Windows Balloon.wav",
    };

    /// %WINDIR%\Media\<name>.
    public static string SystemWav(this SoundEvent e, string? windir = null) =>
        Path.Combine(windir ?? Environment.GetEnvironmentVariable("WINDIR") ?? @"C:\Windows", "Media", e.SystemWavName());

    public static SoundEvent For(Moment m) => m switch
    {
        Moment.NeedsYou => SoundEvent.NeedsYou,
        Moment.Finished => SoundEvent.Finished,
        Moment.Failed => SoundEvent.Failed,
        _ => SoundEvent.Started,
    };
}

/// Which file plays: his own in %APPDATA%\Jarvis\Sounds (wav, mp3, m4a) wins over the system wav.
public static class SoundFiles
{
    public static readonly string[] Extensions = { ".wav", ".mp3", ".m4a" };

    public static string DefaultOverrideDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jarvis", "Sounds");

    public static string? Resolve(SoundEvent e, string overrideDir, Func<string, bool> exists, string? windir = null)
    {
        foreach (var ext in Extensions)
        {
            var p = Path.Combine(overrideDir, e.FileStem() + ext);
            if (exists(p)) return p;
        }
        var sys = e.SystemWav(windir);
        return exists(sys) ? sys : null;
    }
}

public interface ISoundOutput
{
    void Play(string path, double volume);
}

/// Plays a moment's sound unless sounds are off, muted, or a game (or anything fullscreen) is in
/// front: sounds are dropped then, never queued (a backlog of chimes after a match is noise).
public sealed class SoundCenter
{
    private readonly ISoundOutput _out;
    private readonly PrefsStore _prefs;
    private readonly PresentationGate _gate;
    private readonly string _overrideDir;
    private readonly Func<string, bool> _exists;

    public SoundCenter(ISoundOutput output, PrefsStore prefs, PresentationGate gate, string? overrideDir = null, Func<string, bool>? exists = null)
    {
        _out = output;
        _prefs = prefs;
        _gate = gate;
        _overrideDir = overrideDir ?? SoundFiles.DefaultOverrideDir;
        _exists = exists ?? File.Exists;
    }

    public bool Muted { get; set; }

    public bool Play(SoundEvent e)
    {
        if (Muted || !_prefs.Get(PrefKeys.SoundOn) || !_gate.CanPresent) return false;
        if (SoundFiles.Resolve(e, _overrideDir, _exists) is not { } path) return false;
        _out.Play(path, Math.Clamp(_prefs.Get(PrefKeys.SoundVolume), 0, 1));
        return true;
    }
}
