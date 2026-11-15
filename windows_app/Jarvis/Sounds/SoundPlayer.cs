using Jarvis.Core.Sounds;
using NAudio.Wave;

namespace Jarvis.Sounds;

/// Plays one short file (wav, mp3 or m4a via Media Foundation) at a volume, on the default
/// output. Nothing stays open between sounds. SoundCenter decides whether to play at all.
public sealed class SoundPlayer : ISoundOutput
{
    public void Play(string path, double volume)
    {
        try
        {
            var reader = new MediaFoundationReader(path);
            var output = new WaveOutEvent { Volume = (float)Math.Clamp(volume, 0, 1) };
            output.Init(reader);
            output.PlaybackStopped += (_, _) =>
            {
                output.Dispose();
                reader.Dispose();
            };
            output.Play();
        }
        catch (Exception e) when (e is System.IO.IOException or System.Runtime.InteropServices.COMException or InvalidOperationException or NAudio.MmException)
        {
            // A broken custom sound must never break a notification.
        }
    }
}
