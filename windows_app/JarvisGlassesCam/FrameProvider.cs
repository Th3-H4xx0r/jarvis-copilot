using System.Runtime.InteropServices;
using DirectN;
using Jarvis.Core.GlassesCamera;
using JarvisGlassesCam.Utilities;

namespace JarvisGlassesCam
{
    /// Draws each sample the camera hands out: the newest glasses frame the Jarvis app wrote into the
    /// frame file (fitted to the format the app picked), or the "Glasses not streaming" card when
    /// there's none for 2 s (GlassesCamPicture). Never waits on the Jarvis app: with it closed, or
    /// the frame file missing, the card shows and the call carries on. While the stream runs it
    /// counts itself in the frame file and beats once a second, which is how the app knows an app
    /// is using the camera.
    internal sealed unsafe class FrameProvider : IDisposable
    {
        private static readonly GlassesCamCards Cards = new(Resource("card-portrait.png"), Resource("card-landscape.png"));

        private readonly object _lock = new();
        private readonly GlassesCamPicture _picture;
        private GlassesCamFrameFile? _file;
        private long _nextOpen;
        private bool _openFailedLogged;
        private bool _running;
        private bool _counted;
        private Timer? _beat;
        private byte[] _bgra = Array.Empty<byte>();
        private bool? _lastLive;

        public FrameProvider()
        {
            _picture = new GlassesCamPicture(File, size => Cards.For(size));
        }

        private static byte[]? Resource(string name)
        {
            using var s = typeof(FrameProvider).Assembly.GetManifestResourceStream("JarvisGlassesCam." + name);
            if (s == null) return null;
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            return ms.ToArray();
        }

        /// The frame file, opened on first use; when it isn't there (or can't be opened) it is looked
        /// for again at most every 5 s, never on every frame.
        private GlassesCamFrameFile? File()
        {
            lock (_lock)
            {
                if (_file != null) return _file;
                var now = Environment.TickCount64;
                if (now < _nextOpen) return null;
                _nextOpen = now + 5000;
                try
                {
                    _file = GlassesCamFrameFile.Open(GlassesCamSpec.FrameFilePath, create: false);
                    EventProvider.Note("frame file open");
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
                {
                    if (!_openFailedLogged) EventProvider.Note($"frame file unavailable: {e.GetType().Name}: {e.Message}");
                    _openFailedLogged = true;
                }
                return _file;
            }
        }

        public void Started(int width, int height, Guid format)
        {
            lock (_lock)
            {
                if (_running) return;
                _running = true;
                _beat = new Timer(_ => Beat(), null, 0, 1000);
            }
            EventProvider.Note($"stream started {width}x{height} {(format == MFConstants.MFVideoFormat_NV12 ? "NV12" : "RGB32")}");
        }

        public void Stopped()
        {
            lock (_lock)
            {
                if (!_running) return;
                _running = false;
                _beat?.Dispose();
                _beat = null;
                if (_counted) _file?.AddClients(-1);
                _counted = false;
            }
            EventProvider.Note("stream stopped");
        }

        /// Each second while the stream runs: count this stream (once) and refresh the heartbeat.
        private void Beat()
        {
            var file = File();
            lock (_lock)
            {
                if (!_running || file == null) return;
                var now = DateTime.UtcNow;
                if (!_counted)
                {
                    // A count left by a camera service that died (no heartbeat): start from nothing.
                    if (file.ClientsAt(now) == 0) file.Clients = 0;
                    file.AddClients(1);
                    _counted = true;
                }
                file.SourceBeat = now;
            }
        }

        /// One sample's picture, into its (system-memory) buffer.
        public void Draw(IMFSample sample, Guid format, int width, int height)
        {
            sample.GetBufferByIndex(0, out var buffer).ThrowOnError();
            try
            {
                var nv12 = format == MFConstants.MFVideoFormat_NV12;
                if (buffer is IMF2DBuffer twoD && twoD.Lock2D(out var scan0, out var pitch).IsSuccess)
                {
                    try { Write((byte*)scan0, pitch, nv12, width, height); }
                    finally { twoD.Unlock2D(); }
                }
                else
                {
                    buffer.Lock(out var data, IntPtr.Zero, IntPtr.Zero).ThrowOnError();
                    try { Write((byte*)data, nv12 ? width : width * 4, nv12, width, height); }
                    finally { buffer.Unlock(); }
                }
                buffer.SetCurrentLength((uint)(nv12 ? width * height * 3 / 2 : width * height * 4)).ThrowOnError();
            }
            finally
            {
                Marshal.ReleaseComObject(buffer);
            }
        }

        private void Write(byte* dst, int pitch, bool nv12, int width, int height)
        {
            bool live;
            if (!nv12 && pitch > 0)
            {
                live = _picture.Fill(new Span<byte>(dst, pitch * height), width, height, pitch);
            }
            else
            {
                var size = width * height * 4;
                if (_bgra.Length < size) _bgra = new byte[size];
                live = _picture.Fill(_bgra, width, height, width * 4);
                if (nv12)
                {
                    var y = new Span<byte>(dst, pitch * height);
                    var uv = new Span<byte>(dst + (long)pitch * height, pitch * height / 2);
                    GlassesCamPixels.BgraToNv12(_bgra, width, height, width * 4, y, pitch, uv, pitch);
                }
                else
                {
                    // A bottom-up buffer: row 0 at scan0, the next one `pitch` (negative) bytes on.
                    for (var row = 0; row < height; row++)
                        _bgra.AsSpan(row * width * 4, width * 4).CopyTo(new Span<byte>(dst + (long)row * pitch, width * 4));
                }
            }
            if (live != _lastLive) EventProvider.Note(live ? "showing the glasses' video" : "showing the card");
            _lastLive = live;
        }

        public void Dispose()
        {
            Stopped();
            lock (_lock)
            {
                _file?.Dispose();
                _file = null;
            }
        }
    }
}
