using System.IO.MemoryMappedFiles;

namespace Jarvis.Core.GlassesCamera;

/// The newest glasses frame, shared between the Jarvis app (writes it) and the camera's media
/// source inside Windows' camera service (reads it, and writes how many apps use the camera): a
/// memory-mapped file the installer makes at GlassesCamSpec.FrameFilePath.
///
/// Layout (little-endian): a 64-byte header {"JGCM", version 1, seq (long), current slot (int),
/// clients (int), source beat (UTC ticks)} and two slots, each a 32-byte header {width, height,
/// stride, -, frame time (UTC ticks)} and up to 720×1280 BGRA pixels, packed.
///
/// A seqlock with two slots: the writer fills the slot the reader isn't on, flips `current`,
/// and bumps `seq` by 2 (odd while writing). A reader copies the current slot and keeps the copy
/// only if no second write began meanwhile (seq moved by at most 2): the slot it copied is only
/// written again by the write after next. So the camera never shows two frames mixed.
public sealed unsafe class GlassesCamFrameFile : IDisposable
{
    public const int HeaderSize = 64;
    public const int SlotHeaderSize = 32;
    public const int MaxPixelBytes = 720 * 1280 * 4;
    public const int SlotSize = SlotHeaderSize + MaxPixelBytes;
    public const long FileSize = HeaderSize + 2L * SlotSize;
    public const int Version = 1;

    private const uint Magic = 0x4D43474A;   // "JGCM"
    private const int OffMagic = 0, OffVersion = 4, OffSeq = 8, OffSlot = 16, OffClients = 20, OffBeat = 24;
    private const int SlotW = 0, SlotH = 4, SlotStride = 8, SlotTicks = 16;

    private readonly MemoryMappedFile _map;
    private readonly MemoryMappedViewAccessor _view;
    private readonly object _writeLock = new();
    private byte* _p;

    private GlassesCamFrameFile(MemoryMappedFile map, MemoryMappedViewAccessor view)
    {
        _map = map;
        _view = view;
        byte* p = null;
        view.SafeMemoryMappedViewHandle.AcquirePointer(ref p);
        _p = p + view.PointerOffset;
    }

    /// Opens (with `create`, makes) the file. Throws FileNotFoundException when it's missing,
    /// InvalidDataException when it's another size or format (reinstall), and the usual IO errors
    /// when this account may not write it.
    public static GlassesCamFrameFile Open(string path, bool create)
    {
        if (!create && !File.Exists(path)) throw new FileNotFoundException("The camera's frame file is missing.", path);
        if (create) Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var fs = new FileStream(path, create ? FileMode.OpenOrCreate : FileMode.Open, FileAccess.ReadWrite,
            FileShare.ReadWrite | FileShare.Delete);
        MemoryMappedFile map;
        try
        {
            if (fs.Length == 0 && create) fs.SetLength(FileSize);
            if (fs.Length != FileSize) throw new InvalidDataException($"The camera's frame file is {fs.Length} bytes, not {FileSize}.");
            map = MemoryMappedFile.CreateFromFile(fs, null, FileSize, MemoryMappedFileAccess.ReadWrite, HandleInheritability.None, leaveOpen: false);
        }
        catch
        {
            fs.Dispose();
            throw;
        }
        MemoryMappedViewAccessor view;
        try { view = map.CreateViewAccessor(0, FileSize, MemoryMappedFileAccess.ReadWrite); }
        catch
        {
            map.Dispose();
            throw;
        }
        var file = new GlassesCamFrameFile(map, view);
        try { file.CheckHeader(); }
        catch
        {
            file.Dispose();
            throw;
        }
        return file;
    }

    private void CheckHeader()
    {
        var magic = *(uint*)(_p + OffMagic);
        var version = *(int*)(_p + OffVersion);
        if (magic == 0 && version == 0)
        {
            // A new (zero-filled) file: whoever opens it first stamps it. Same values either way.
            *(int*)(_p + OffVersion) = Version;
            Volatile.Write(ref *(uint*)(_p + OffMagic), Magic);
            return;
        }
        if (magic != Magic || version != Version)
            throw new InvalidDataException("The camera's frame file is from another version of Jarvis. Reinstall the camera.");
    }

    private ref long Seq => ref *(long*)(_p + OffSeq);
    private ref int CurrentSlot => ref *(int*)(_p + OffSlot);
    private byte* Slot(int i) => _p + HeaderSize + (long)(i & 1) * SlotSize;

    /// One BGRA frame (`stride` bytes per row, at most 720×1280 pixels) in as the newest.
    public void WriteFrame(ReadOnlySpan<byte> bgra, int width, int height, int stride, DateTime utc)
    {
        if (width <= 0 || height <= 0 || (long)width * height * 4 > MaxPixelBytes)
            throw new ArgumentException($"A {width}×{height} frame doesn't fit the camera's frame file.");
        if (stride < width * 4 || bgra.Length < (long)stride * (height - 1) + width * 4)
            throw new ArgumentException("The frame's buffer is smaller than its size says.");
        lock (_writeLock)
        {
            var seq = Volatile.Read(ref Seq);
            if ((seq & 1) != 0) seq++;   // a writer died mid-frame: start clean
            var target = 1 - (Volatile.Read(ref CurrentSlot) & 1);
            Interlocked.Exchange(ref Seq, seq + 1);   // odd: writing (a full fence before the pixels)
            var slot = Slot(target);
            var row = width * 4;
            var dst = new Span<byte>(slot + SlotHeaderSize, MaxPixelBytes);
            if (stride == row) bgra[..(row * height)].CopyTo(dst);
            else
                for (var y = 0; y < height; y++) bgra.Slice(y * stride, row).CopyTo(dst.Slice(y * row, row));
            *(int*)(slot + SlotW) = width;
            *(int*)(slot + SlotH) = height;
            *(int*)(slot + SlotStride) = row;
            *(long*)(slot + SlotTicks) = utc.ToUniversalTime().Ticks;
            Volatile.Write(ref CurrentSlot, target);
            Volatile.Write(ref Seq, seq + 2);   // even again (a release: everything above is visible first)
        }
    }

    /// The newest frame, packed (width × 4 bytes per row), into `dst`. False when there's none
    /// yet, it doesn't fit `dst`, or the writer overtook the copy twice.
    public bool TryReadLatest(Span<byte> dst, out int width, out int height, out DateTime utc)
    {
        width = height = 0;
        utc = default;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var s1 = Volatile.Read(ref Seq);
            for (var spin = 0; (s1 & 1) != 0 && spin < 200; spin++)
            {
                Thread.SpinWait(20);
                s1 = Volatile.Read(ref Seq);
            }
            if (s1 == 0 || (s1 & 1) != 0) return false;
            var slot = Slot(Volatile.Read(ref CurrentSlot));
            var w = Volatile.Read(ref *(int*)(slot + SlotW));
            var h = *(int*)(slot + SlotH);
            var ticks = *(long*)(slot + SlotTicks);
            var bytes = (long)w * h * 4;
            if (w <= 0 || h <= 0 || bytes > MaxPixelBytes) return false;
            if (bytes > dst.Length) return false;
            new ReadOnlySpan<byte>(slot + SlotHeaderSize, (int)bytes).CopyTo(dst);
            Interlocked.MemoryBarrier();
            var s2 = Volatile.Read(ref Seq);
            if (s2 - s1 > 2) continue;   // the slot was rewritten under the copy
            width = w;
            height = h;
            utc = new DateTime(ticks, DateTimeKind.Utc);
            return true;
        }
        return false;
    }

    /// When the newest frame was written (null: none yet). A cheap look, no pixels.
    public DateTime? LastFrameUtc
    {
        get
        {
            if (Volatile.Read(ref Seq) == 0) return null;
            var ticks = Volatile.Read(ref *(long*)(Slot(Volatile.Read(ref CurrentSlot)) + SlotTicks));
            return ticks <= 0 ? null : new DateTime(ticks, DateTimeKind.Utc);
        }
    }

    /// Streams the source is running (the camera service sets it).
    public int Clients
    {
        get => Math.Max(0, Volatile.Read(ref *(int*)(_p + OffClients)));
        set => Volatile.Write(ref *(int*)(_p + OffClients), Math.Max(0, value));
    }

    /// Adds to Clients atomically (across processes); never below zero. Returns the new count.
    public int AddClients(int by)
    {
        ref var c = ref *(int*)(_p + OffClients);
        while (true)
        {
            var old = Volatile.Read(ref c);
            var next = Math.Max(0, old + by);
            if (Interlocked.CompareExchange(ref c, next, old) == old) return next;
        }
    }

    /// The source's heartbeat (each second while a stream runs).
    public DateTime SourceBeat
    {
        get => new(Math.Max(0, Volatile.Read(ref *(long*)(_p + OffBeat))), DateTimeKind.Utc);
        set => Volatile.Write(ref *(long*)(_p + OffBeat), value.ToUniversalTime().Ticks);
    }

    /// Apps using the camera as of `now`: the count, unless the heartbeat went stale (the camera
    /// service died with the count up).
    public int ClientsAt(DateTime now) =>
        now.ToUniversalTime() - SourceBeat > GlassesCamSpec.BeatStaleAfter ? 0 : Clients;

    public void Dispose()
    {
        if (_p != null)
        {
            _view.SafeMemoryMappedViewHandle.ReleasePointer();
            _p = null;
        }
        _view.Dispose();
        _map.Dispose();
    }
}
