using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Recognition;
using Jarvis.Core.Voice;

namespace Jarvis.Voice.Audio;

/// The words check's ears: Windows' own dictation recogniser (System.Speech) fed the echo-cancelled
/// mic while a sound over the reply is being checked. Created on first use and kept for the
/// conversation; fed only during a check. Missing (no speech recogniser installed) → null, and
/// the check is energy-only, as on the phone.
public sealed class SapiWordsRecognizer : IWordsRecognizer, IDisposable
{
    private readonly PcmPipe _pipe = new();
    private SpeechRecognitionEngine? _engine;
    private volatile bool _accepting;
    private string? _latest;

    public static SapiWordsRecognizer? TryCreate()
    {
        try
        {
            return SpeechRecognitionEngine.InstalledRecognizers().Count > 0 ? new SapiWordsRecognizer() : null;
        }
        catch (Exception e) when (e is PlatformNotSupportedException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }

    public void Begin()
    {
        _latest = null;
        if (_engine == null)
        {
            _engine = new SpeechRecognitionEngine();
            _engine.LoadGrammar(new DictationGrammar());
            _engine.SetInputToAudioStream(_pipe, new SpeechAudioFormatInfo(16000, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
            _engine.SpeechHypothesized += (_, e) => { if (_accepting) _latest = e.Result.Text; };
            _engine.SpeechRecognized += (_, e) => { if (_accepting) _latest = e.Result.Text; };
            _engine.RecognizeAsync(RecognizeMode.Multiple);
        }
        _accepting = true;
    }

    public void Feed(ReadOnlyMemory<short> pcm)
    {
        if (!_accepting) return;
        var bytes = new byte[pcm.Length * 2];
        Buffer.BlockCopy(pcm.ToArray(), 0, bytes, 0, bytes.Length);
        _pipe.Push(bytes);
    }

    public string? TakeLatest() => Interlocked.Exchange(ref _latest, null);

    public void End() => _accepting = false;

    public void Dispose()
    {
        _accepting = false;
        _pipe.Complete();
        try { _engine?.RecognizeAsyncCancel(); } catch (InvalidOperationException) { }
        _engine?.Dispose();
    }

    /// A blocking read-only stream the recogniser pulls PCM from.
    private sealed class PcmPipe : Stream
    {
        private readonly Queue<byte[]> _chunks = new();
        private byte[]? _current;
        private int _offset;
        private bool _done;

        public void Push(byte[] b) { lock (_chunks) { _chunks.Enqueue(b); Monitor.PulseAll(_chunks); } }
        public void Complete() { lock (_chunks) { _done = true; Monitor.PulseAll(_chunks); } }

        public override int Read(byte[] buffer, int offset, int count)
        {
            lock (_chunks)
            {
                while ((_current == null || _offset >= _current.Length) && _chunks.Count == 0 && !_done) Monitor.Wait(_chunks);
                if (_current == null || _offset >= _current.Length)
                {
                    if (_chunks.Count == 0) return 0;
                    _current = _chunks.Dequeue();
                    _offset = 0;
                }
                var n = Math.Min(count, _current.Length - _offset);
                Buffer.BlockCopy(_current, _offset, buffer, offset, n);
                _offset += n;
                return n;
            }
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
