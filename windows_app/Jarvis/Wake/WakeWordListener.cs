using Jarvis.Core.Wake;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Jarvis.Wake;

/// "Hey Jarvis" on the device with openWakeWord through ONNX Runtime: 80 ms chunks → mel frames
/// → 76-frame windows → 96-d embeddings → the last 16 → the hey_jarvis score → WakeGate. One
/// thread per model session, so it stays on one core. Shared-mode capture of the default mic;
/// paused whenever a conversation owns the mic.
public sealed class WakeWordListener : IDisposable
{
    private const int Overlap = 480;   // openWakeWord feeds 3 extra hops of context to the mel model
    private readonly InferenceSession _mel, _embed, _wake;
    private readonly OwwFeatures _features = new();
    private readonly WakeGate _gate = new();
    private readonly List<short> _raw = new();
    private readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();
    private short[] _context = new short[Overlap];
    private WasapiCapture? _capture;
    private double _phase;

    public WakeWordListener(string modelDir)
    {
        var opts = new SessionOptions { IntraOpNumThreads = 1, InterOpNumThreads = 1, ExecutionMode = ExecutionMode.ORT_SEQUENTIAL };
        _mel = new InferenceSession(System.IO.Path.Combine(modelDir, "melspectrogram.onnx"), opts);
        _embed = new InferenceSession(System.IO.Path.Combine(modelDir, "embedding_model.onnx"), opts);
        _wake = new InferenceSession(System.IO.Path.Combine(modelDir, "hey_jarvis_v0.1.onnx"), opts);
    }

    public static string DefaultModelDir => System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "wakeword");

    public bool Listening => _capture != null;
    public event Action? Heard;
    public event Action<string>? Log;

    public void Start()
    {
        if (_capture != null) return;
        try
        {
            _capture = new WasapiCapture { ShareMode = AudioClientShareMode.Shared };
            _capture.DataAvailable += OnData;
            _capture.StartRecording();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            Log?.Invoke($"wake capture failed: {e.Message}");
            _capture = null;
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
        _raw.Clear();
        _features.Reset();
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (_capture is not { } c) return;
        var fmt = c.WaveFormat;
        Append(e.Buffer, e.BytesRecorded, fmt);
        while (_raw.Count >= OwwFeatures.ChunkSamples)
        {
            var chunk = _raw.GetRange(0, OwwFeatures.ChunkSamples).ToArray();
            _raw.RemoveRange(0, OwwFeatures.ChunkSamples);
            Process(chunk);
        }
    }

    /// The mix format (often 48 kHz float stereo) → 16 kHz mono int16.
    private void Append(byte[] buf, int n, WaveFormat fmt)
    {
        var bytesPer = fmt.BitsPerSample / 8;
        var frames = n / (bytesPer * fmt.Channels);
        var step = fmt.SampleRate / 16000.0;
        for (; _phase < frames; _phase += step)
        {
            var i = (int)_phase;
            double sum = 0;
            for (var ch = 0; ch < fmt.Channels; ch++)
            {
                var at = (i * fmt.Channels + ch) * bytesPer;
                sum += fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt.Encoding == WaveFormatEncoding.Extensible && bytesPer == 4)
                    ? BitConverter.ToSingle(buf, at)
                    : bytesPer == 2 ? BitConverter.ToInt16(buf, at) / 32768.0 : 0;
            }
            _raw.Add((short)Math.Clamp(sum / fmt.Channels * 32767, short.MinValue, short.MaxValue));
        }
        _phase -= frames;
    }

    private void Process(short[] chunk)
    {
        // Mel frames for this chunk (with the previous chunk's tail as context).
        var input = new float[Overlap + chunk.Length];
        for (var i = 0; i < Overlap; i++) input[i] = _context[i];
        for (var i = 0; i < chunk.Length; i++) input[Overlap + i] = chunk[i];
        _context = chunk[^Overlap..];
        using var melOut = _mel.Run(new[] { NamedOnnxValue.CreateFromTensor(_mel.InputMetadata.Keys.First(), new DenseTensor<float>(input, new[] { 1, input.Length })) });
        var mel = melOut.First().AsTensor<float>();
        var frames = mel.Dimensions[^2];
        var bins = mel.Dimensions[^1];
        var m = new float[frames, OwwFeatures.MelBins];
        var flat = mel.ToArray();
        for (var f = 0; f < frames; f++)
            for (var b = 0; b < Math.Min(bins, OwwFeatures.MelBins); b++)
                m[f, b] = OwwFeatures.Transform(flat[f * bins + b]);
        _features.PushMel(m);

        while (_features.TryTakeMelWindow(out var window))
        {
            using var embOut = _embed.Run(new[] { NamedOnnxValue.CreateFromTensor(_embed.InputMetadata.Keys.First(),
                new DenseTensor<float>(window, new[] { 1, OwwFeatures.MelWindow, OwwFeatures.MelBins, 1 })) });
            _features.PushEmbedding(embOut.First().AsTensor<float>().ToArray());
            if (!_features.TryEmbeddingWindow(out var emb)) continue;
            using var scoreOut = _wake.Run(new[] { NamedOnnxValue.CreateFromTensor(_wake.InputMetadata.Keys.First(),
                new DenseTensor<float>(emb, new[] { 1, OwwFeatures.EmbeddingWindow, OwwFeatures.EmbeddingSize })) });
            var score = scoreOut.First().AsTensor<float>().ToArray().DefaultIfEmpty(0).Max();
            if (_gate.Allow(score, _clock.Elapsed.TotalSeconds))
            {
                Log?.Invoke($"wake score={score:0.00}");
                Heard?.Invoke();
            }
        }
    }

    public void Dispose()
    {
        Stop();
        _mel.Dispose();
        _embed.Dispose();
        _wake.Dispose();
    }
}
