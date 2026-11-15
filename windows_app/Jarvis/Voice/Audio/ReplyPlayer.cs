using System.IO;
using Jarvis.Core.Voice;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Jarvis.Voice.Audio;

/// The reply's speaker: WASAPI shared output on the chosen render device, fed by one queue at
/// 24 kHz mono PCM16. PCM clips are resampled to 24 kHz when needed; MP3 clips are decoded frame
/// by frame (ACM) and resampled. PlayedMs counts real reply samples the device consumed (not the
/// silence it pads with), which is the karaoke clock. Volume ducks for the words check.
public sealed class ReplyPlayer : IReplyPlayer, IDisposable
{
    private const int Rate = 24000;
    private readonly object _lock = new();
    private readonly ReplyQueue _queue = new(new WaveFormat(Rate, 16, 1));
    private readonly MemoryStream _mp3 = new();
    private WasapiOut? _out;
    private MMDevice? _device;
    private IMp3FrameDecompressor? _decoder;
    private float _volume = 1f;

    public ReplyPlayer() => _queue.Drained += () => Drained?.Invoke();

    public long PlayedMs => _queue.PlayedSamples * 1000 / Rate;
    public long QueuedMs => _queue.QueuedSamples * 1000 / Rate;
    public bool Draining => _queue.Busy;
    public event Action? Drained;

    public void Start(string renderId)
    {
        lock (_lock)
        {
            Stop();
            using var e = new MMDeviceEnumerator();
            _device = renderId.Length > 0 ? e.GetDevice(renderId) : e.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            _out = new WasapiOut(_device, AudioClientShareMode.Shared, true, 60);
            _out.Init(_queue);
            _out.Volume = _volume;
            _out.Play();
        }
    }

    public void Enqueue(string format, int rate, ReadOnlyMemory<byte> data)
    {
        lock (_lock)
        {
            if (format.StartsWith("mp3", StringComparison.OrdinalIgnoreCase)) DecodeMp3(data.Span);
            else _queue.Add(Resample(data.Span, rate <= 0 ? Rate : rate));
        }
    }

    public void EndSegment() => _queue.SegmentEnded();

    public void Flush()
    {
        lock (_lock)
        {
            _queue.Clear();
            _mp3.SetLength(0);
            _decoder?.Reset();
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            _out?.Stop();
            _out?.Dispose();
            _out = null;
            _device?.Dispose();
            _device = null;
            _decoder?.Dispose();
            _decoder = null;
            _queue.Clear();
            _mp3.SetLength(0);
        }
    }

    public void SetVolume(float v)
    {
        _volume = Math.Clamp(v, 0f, 1f);
        if (_out != null) _out.Volume = _volume;
    }

    private void DecodeMp3(ReadOnlySpan<byte> data)
    {
        _mp3.Seek(0, SeekOrigin.End);
        _mp3.Write(data);
        _mp3.Position = 0;
        var pcm = new byte[16384 * 4];
        while (true)
        {
            var start = _mp3.Position;
            Mp3Frame? frame;
            try { frame = Mp3Frame.LoadFromStream(_mp3); }
            catch (EndOfStreamException) { frame = null; }
            if (frame == null) { _mp3.Position = start; break; }
            _decoder ??= new AcmMp3FrameDecompressor(new Mp3WaveFormat(frame.SampleRate, frame.ChannelMode == ChannelMode.Mono ? 1 : 2, frame.FrameLength, frame.BitRate));
            var n = _decoder.DecompressFrame(frame, pcm, 0);
            var fmt = _decoder.OutputFormat;
            _queue.Add(Resample(ToMono(pcm.AsSpan(0, n), fmt.Channels), fmt.SampleRate));
        }
        // Keep only the undecoded tail.
        var rest = _mp3.Length - _mp3.Position;
        var tail = new byte[rest];
        _mp3.Read(tail, 0, (int)rest);
        _mp3.SetLength(0);
        _mp3.Write(tail);
    }

    private static byte[] ToMono(ReadOnlySpan<byte> pcm, int channels)
    {
        if (channels <= 1) return pcm.ToArray();
        var frames = pcm.Length / (2 * channels);
        var mono = new byte[frames * 2];
        for (var i = 0; i < frames; i++)
        {
            var sum = 0;
            for (var c = 0; c < channels; c++) sum += (short)(pcm[(i * channels + c) * 2] | (pcm[(i * channels + c) * 2 + 1] << 8));
            var s = (short)(sum / channels);
            mono[i * 2] = (byte)s;
            mono[i * 2 + 1] = (byte)(s >> 8);
        }
        return mono;
    }

    /// Linear resampling to 24 kHz: speech only, so this is plenty.
    private static byte[] Resample(ReadOnlySpan<byte> pcm, int from)
    {
        if (from == Rate) return pcm.ToArray();
        var inCount = pcm.Length / 2;
        if (inCount == 0) return Array.Empty<byte>();
        var outCount = (int)((long)inCount * Rate / from);
        var o = new byte[outCount * 2];
        for (var i = 0; i < outCount; i++)
        {
            var pos = (double)i * from / Rate;
            var j = (int)pos;
            var frac = pos - j;
            short a = (short)(pcm[j * 2] | (pcm[j * 2 + 1] << 8));
            var k = Math.Min(j + 1, inCount - 1);
            short b = (short)(pcm[k * 2] | (pcm[k * 2 + 1] << 8));
            var s = (short)(a + (b - a) * frac);
            o[i * 2] = (byte)s;
            o[i * 2 + 1] = (byte)(s >> 8);
        }
        return o;
    }

    public void Dispose() => Stop();

    /// The device pulls from here: real reply bytes when there are any, silence otherwise.
    private sealed class ReplyQueue : IWaveProvider
    {
        private readonly object _lock = new();
        private readonly Queue<byte[]> _chunks = new();
        private byte[]? _current;
        private int _offset;
        private bool _ended = true;
        private bool _played;

        public ReplyQueue(WaveFormat format) => WaveFormat = format;

        public WaveFormat WaveFormat { get; }
        public long PlayedSamples { get; private set; }
        public long QueuedSamples { get; private set; }
        public bool Busy { get { lock (_lock) return _current != null || _chunks.Count > 0 || !_ended; } }
        public event Action? Drained;

        public void Add(byte[] pcm)
        {
            if (pcm.Length == 0) return;
            lock (_lock)
            {
                _chunks.Enqueue(pcm);
                QueuedSamples += pcm.Length / 2;
                _ended = false;
            }
        }

        public void SegmentEnded() { lock (_lock) _ended = true; }

        public void Clear()
        {
            lock (_lock)
            {
                _chunks.Clear();
                _current = null;
                _offset = 0;
                _ended = true;
                _played = false;
            }
        }

        public int Read(byte[] buffer, int offset, int count)
        {
            var real = 0;
            var drained = false;
            lock (_lock)
            {
                while (real < count)
                {
                    if (_current == null || _offset >= _current.Length)
                    {
                        if (_chunks.Count == 0) { _current = null; break; }
                        _current = _chunks.Dequeue();
                        _offset = 0;
                    }
                    var n = Math.Min(count - real, _current.Length - _offset);
                    Buffer.BlockCopy(_current, _offset, buffer, offset + real, n);
                    _offset += n;
                    real += n;
                }
                PlayedSamples += real / 2;
                if (real > 0) _played = true;
                if (real < count && _played && _ended && _chunks.Count == 0)
                {
                    _played = false;
                    drained = true;
                }
            }
            Array.Clear(buffer, offset + real, count - real);
            if (drained) ThreadPool.QueueUserWorkItem(_ => Drained?.Invoke());
            return count;
        }
    }
}
