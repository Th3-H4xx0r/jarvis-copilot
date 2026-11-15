using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Jarvis.Voice.Audio;

/// Shared-mode capture of the default mic (or, with `loopback`, what the PC is playing) turned
/// into 16 kHz mono PCM16 chunks. Used by Live, Flow and the note-taker; each starts it only on
/// his explicit action and stops it when done.
public sealed class Mic16k : IDisposable
{
    private readonly bool _loopback;
    private WasapiCapture? _capture;
    private double _phase;

    public Mic16k(bool loopback = false) => _loopback = loopback;

    public bool Running => _capture != null;
    public event Action<short[]>? Samples;
    public event Action<string>? Failed;

    public void Start()
    {
        if (_capture != null) return;
        try
        {
            _capture = _loopback ? new WasapiLoopbackCapture() : new WasapiCapture { ShareMode = AudioClientShareMode.Shared };
            _capture.DataAvailable += OnData;
            _capture.RecordingStopped += (_, e) => { if (e.Exception != null) Failed?.Invoke(e.Exception.Message); };
            _phase = 0;
            _capture.StartRecording();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            _capture = null;
            Failed?.Invoke(e.Message);
        }
    }

    public void Stop()
    {
        var c = _capture;
        _capture = null;
        if (c == null) return;
        c.DataAvailable -= OnData;
        try { c.StopRecording(); } catch (InvalidOperationException) { }
        c.Dispose();
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (_capture is not { } c || e.BytesRecorded == 0) return;
        Samples?.Invoke(To16kMono(e.Buffer, e.BytesRecorded, c.WaveFormat, ref _phase));
    }

    /// The mix format (often 48 kHz float stereo) → 16 kHz mono int16 (nearest-sample decimation
    /// with channel averaging: speech only).
    public static short[] To16kMono(byte[] buf, int n, WaveFormat fmt, ref double phase)
    {
        var bytesPer = Math.Max(1, fmt.BitsPerSample / 8);
        var frames = n / (bytesPer * fmt.Channels);
        var step = fmt.SampleRate / 16000.0;
        var isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt.Encoding == WaveFormatEncoding.Extensible && bytesPer == 4);
        var outList = new List<short>((int)(frames / step) + 2);
        for (; phase < frames; phase += step)
        {
            var i = (int)phase;
            double sum = 0;
            for (var ch = 0; ch < fmt.Channels; ch++)
            {
                var at = (i * fmt.Channels + ch) * bytesPer;
                sum += isFloat ? BitConverter.ToSingle(buf, at) : bytesPer == 2 ? BitConverter.ToInt16(buf, at) / 32768.0 : 0;
            }
            outList.Add((short)Math.Clamp(sum / fmt.Channels * 32767, short.MinValue, short.MaxValue));
        }
        phase -= frames;
        return outList.ToArray();
    }

    public void Dispose() => Stop();
}
